//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "hardhat/console.sol"; // TODO: Remove this for production
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeRouter02.sol";
import "@openzeppelin/contracts/utils/math/Math.sol"; // min()

// local
import "contracts/IERC20.sol";
import "contracts/SwapRouter.sol";
import "contracts/Library.sol";
import "contracts/InvestmentManager.sol";
import "contracts/ICashManager.sol";
import "contracts/IMaldenFeuersteinERC20.sol";

// Typical usage:
// The owner of CashManager calls setCashAllocations to set the target percentages of each cash asset on hand
// Someone invests AVAX into the MaldenFeuersteinERC20 token by calling invest()
// MaldenFeuersteinERC20 wraps the AVAX into WAVAX and sends it to this CashManager contract
// 1) Anyone calls updateCashPrices() at any time to update the contracts stored prices of each cash asset
// 2) Anyone calls updateLiquidationsAndPurchases() at most once per day to queue up the liquidations and purchases necessary to reach the desired cash asset allocations
// 3) Anyone calls processLiquidation() repeatedly until all queued liquidations are processed.
// 4) After all liquidations are completed, anyone calls processPurchase() repeatedly until all queued purchases are processed.
// 5) If any of the liquidations or purchases were completed only partially because the orders were too big given the price impact requirements, steps 1-4 can be repeated on the following day to move closer to the desired cash allocations.

contract CashManager is OwnableUpgradeable, UUPSUpgradeable, ICashManager, PausableUpgradeable {
    event AddedCashAsset(address);
    event RemovedCashAsset(address);
    event IncreasedCashAsset(address);
    event DecreasedCashAsset(address);
    event Liquidated(address); // emitted when an asset is liquidated because it's no longer a cash holding
    event Purchased(address); // emitted when an asset is purchased to reach target cash holding percentage

    // Mapping of assets to percentages of USD value to allocate to each, percentages must sum to 100 * (10 ** 6)
    mapping(address => uint256) private cashAssetsAllocations;
    // Mapping of assets to most recent prices in USDT
    mapping(address => uint256) private cashAssetsPrices;
    // Can have at most uint16 max value length = 65535
    address[] public cashAssets; // An array of all cash assets to iterate across the cashAssetsAllocations mapping
    // Relying on a whole day of time transpiring here, it's unlikely that miners can manipulate timestamp this much
    uint256 public lastCashBalanceUpdateTimestamp; 
    uint256 public lastCashAssetsPricesUpdateBlockNumber;
    mapping(address => address[]) private liquidatePaths;
    mapping(address => address[]) private purchasePaths;
    mapping(address => uint256) private targetUSDValues;
    mapping(address => uint256) private currentUSDValues;
    mapping(address => uint256) private assetLiquidationAmounts; // Amount of each token to sell, denominated in token
    mapping(address => uint256) private assetPurchaseAmounts; // Amount of each token to buy, denominated in token
    address[] liquidationsToPerform;
    address[] purchasesToPerform;
    // Amount of WAVAX reserved for making investment purchases. This amount of WAVAX cannot be used to purchase
    // other cash holdings
    uint256 private investmentReservedWAVAXAmount;

    // contracts
    SwapRouter private router;
    IWAVAX private wavax;
    IERC20 private usdt;
    IJoeRouter02 private joeRouter; // TODO: this should probably be set on construction
    InvestmentManager private investmentManager; // Handles deciding when to buy and sell assets based on value investment principles
    IMaldenFeuersteinERC20 private coin;

    // constants
    // As of this writing average Avalanche C-Chain block time is 2 seconds
    // https://snowtrace.io/chart/blocktime
    uint256 private newBlockEveryNMicroseconds; 
    uint256 private totalUSDValue;
    uint256 private minimumSwapValue;
    uint256 private priceImpactTolerance; // price impact micro percentage
    uint256 private slippageTolerance; // swap slippage tolerance in micro percentage
    uint256 private minimumAllocationDifference; // minimum percentage allocation must differ to queue a swap for it
    uint256 private constant ONE_HUNDRED_PERCENT = 100 * (10**6);

    function initialize(address swapRouterAddress, address investmentManagerAddress) external virtual initializer {
        // TODO: Make these upgradable
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        lastCashBalanceUpdateTimestamp = 0;
        lastCashAssetsPricesUpdateBlockNumber = 0;
        newBlockEveryNMicroseconds = 2000;
        totalUSDValue = 0;
        priceImpactTolerance = 1 * (10 ** 6); // 1%
        router = SwapRouter(swapRouterAddress);
        wavax = IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
        usdt = IERC20(0xc7198437980c041c805A1EDcbA50c1Ce5db95118);
        minimumSwapValue = 50 * (10 ** usdt.decimals()); // Don't bother swapping less than $50
        minimumAllocationDifference = 1 * (10 ** 6); // 1%
        joeRouter = IJoeRouter02(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
        slippageTolerance = 5 * (10 ** 6) / 10; // 0.5%
        investmentManager = InvestmentManager(investmentManagerAddress);
        investmentReservedWAVAXAmount = 0;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function pause() external whenNotPaused onlyOwner {
        _pause();
    }

    function unpause() external whenPaused onlyOwner {
        _unpause();
    }

    function setCoinAddress(address coinAddress) external onlyOwner whenNotPaused { // only owner can call this
        coin = IMaldenFeuersteinERC20(coinAddress);
    }

    // Convenience function
    function numberOfCashAssets() external view returns(uint length) {
        return cashAssets.length;
    }

    // Owner tells the contract to change how it holds "cash" prior to investing it
    // This liquidates any holdings that were previously in the cashAssets and were removed
    // TODO: Test calling this with very long list of assets. How large does it need to be to hit the gas limit due to these
    //    for loops over dynamic arrays?
    function setCashAllocations(address[] calldata assets,
                                uint256[] calldata percentages,
                                address[][] calldata passedLiquidatePaths,
                                address[][] calldata passedPurchasePaths) external onlyOwner whenNotPaused {
        require(assets.length < 50, "Can not have more than 50 cash assets."); // This prevents issues with loops and gas
        require(assets.length == percentages.length, "Assets and percentages arrays must be the same length.");
        // TODO: I need these to be uncommented when I get this contract within the size limit
        require(passedLiquidatePaths.length == assets.length, "Must have a liquidatePath for each asset.");
        require(passedPurchasePaths.length == assets.length, "Must have a purchasePath for each asset.");
        uint sum = 0;
        for(uint i = 0; i < percentages.length; i++) {
            require(percentages[i] > 0, "Can't assign a cash asset to a portfolio weight of 0%.");
            sum += percentages[i];
        }
        require(sum == (100 * (10 ** 6)), "The percentages must sum to exactly 100 * (10 ** 6).");

        address[] memory oldAssets = cashAssets;
        delete cashAssets; // reset
        assert(cashAssets.length == 0); // make sure the array is starting over
        for (uint i = 0; i < oldAssets.length; i++) { // reset the mapping
            cashAssetsAllocations[oldAssets[i]] = 0;
        }
        for (uint i = 0; i < assets.length; i++) { // assign the new values
            address asset = assets[i];
            cashAssets.push(asset);
            cashAssetsAllocations[asset] = percentages[i];
            liquidatePaths[asset] = passedLiquidatePaths[i];
            // All purchases start in WAVAX currently
            if (asset != address(wavax)) {
                require(passedPurchasePaths[i][0] == address(wavax), "All purchase paths must begin with WAVAX.");
                require(passedLiquidatePaths[i][passedLiquidatePaths[i].length - 1] == address(wavax),
                        "All liquidate paths must end with WAVAX.");
            }
            purchasePaths[asset] = passedPurchasePaths[i];
        }
        // Liquidate removals
        for (uint i = 0; i < oldAssets.length; i++) { // The asset was allocated previously
            if (cashAssetsAllocations[oldAssets[i]] == 0) { // But it has been removed in the new allocations
                address asset = oldAssets[i];
                emit RemovedCashAsset(asset);
                IERC20 token = IERC20(asset);
                if (token.balanceOf(address(this)) > 0) {
                    if (asset != address(wavax)) { // WAVAX is the liquidated asset temprary holding
                        // Set state before external calls
                        emit Liquidated(asset);
                        uint256 desiredAmountToSwap = token.balanceOf(address(this));
                        address[] memory path = liquidatePaths[asset];
                        uint256 amountToSwap;
                        uint256 expectedReceived;
                        (amountToSwap, expectedReceived) = router.findSwapAmountWithinTolerance(path,
                                                                                                desiredAmountToSwap,
                                                                                                priceImpactTolerance);
                        // If not fully liquidating it, then keep it in the asset list to process further liquidations
                        if (amountToSwap != desiredAmountToSwap) { 
                            cashAssets.push(asset);
                        }
                        IERC20 fromToken = IERC20(path[0]);
                        bool success = fromToken.approve(address(joeRouter), amountToSwap);
                        require(success, "token approval failed.");

                        // Do the swap
                        uint256 minimumReceived = Library.subtractPercentage(expectedReceived, slippageTolerance);
                        uint256[] memory amounts = joeRouter.swapExactTokensForTokens(amountToSwap,
                                                                                      minimumReceived, // Define a minimum received
                                                                                      path,
                                                                                      address(this),
                                                                                      block.timestamp);
                        require(amounts[0] == amountToSwap, "Didn't sell the amount of tokens inserted.");
                        require(amounts[amounts.length - 1] >= minimumReceived, "Didn't get out as much as expected."); 
                    }
                }
            }
        }
    }

    // This can be called by anyone at anytime to keep the prices up to date
    function updateCashPrices() external whenNotPaused {
        // Get the price in USD of every cash asset on hand
        SwapRouter.PriceQuote memory wavaxInUSDTQuote = router.getPriceQuote(address(wavax), address(usdt));
        if (cashAssetsPrices[address(wavax)] > 0) {
            // TODO: Owner should be able to change this 10x factor
            require(wavaxInUSDTQuote.price < cashAssetsPrices[address(wavax)] * 10,
                    "Price going up more than 10x, something is wrong.");
            require(wavaxInUSDTQuote.price > cashAssetsPrices[address(wavax)] / 10,
                   "Price going down by more than 10x, something is wrong.");
        }
        cashAssetsPrices[address(wavax)] = wavaxInUSDTQuote.price;

        uint8 unit_of_denomination_decimals = usdt.decimals();
        uint8 wavax_decimals = wavax.decimals();
        for (uint32 i = 0; i < cashAssets.length; i++) {
            address asset = cashAssets[i];
            if (asset == address(usdt)) {
                cashAssetsPrices[asset] = 10 ** unit_of_denomination_decimals; // USDT:USDT is 1:1 definitionally
            } else if (asset != address(wavax)) { // WAVAX price was already updated
                // First convert to WAVAX, then convert to USDT
                SwapRouter.PriceQuote memory quoteInWAVAX = router.getPriceQuote(asset, address(wavax));
                // TODO: Test this on an asset that has fewer decimals than USDT
                uint256 priceInUSDT = Library.priceMulAmount(quoteInWAVAX.price, wavax_decimals, wavaxInUSDTQuote.price);
                if (cashAssetsPrices[asset] > 0) {
                    require(priceInUSDT < (cashAssetsPrices[asset] * 10),
                           "Price going up more than 10x, something is wrong.");
                    require(priceInUSDT > (cashAssetsPrices[asset] / 10),
                           "Price going down more than 10x, something is wrong.");
                }
                cashAssetsPrices[asset] = priceInUSDT;
            }
        }
        lastCashAssetsPricesUpdateBlockNumber = block.number;
    }

    // This can be called by anyone at most once per day, and the cash assets prices must have been updated within the
    // past minute
    function updateLiquidationsAndPurchases() external whenNotPaused { // anyone can call this
        // Limit how often this is called
        // TODO Make this time limit a parameter that can be set. Once per day could be too much. People spamming this
        // would be a nuisance on transaction costs
        require(block.timestamp > lastCashBalanceUpdateTimestamp + 86400, "Can update cash balances only once per day.");
        // Speed bump: https://samczsun.com/so-you-want-to-use-a-price-oracle/
        require(block.number > lastCashAssetsPricesUpdateBlockNumber, "Cannot update prices and balances in the same block.");
        require(block.number < lastCashAssetsPricesUpdateBlockNumber + ((60 * 1000) / newBlockEveryNMicroseconds),
                "Cash asset prices are older than one minute.");
        require(investmentReservedWAVAXAmount == 0,
                "Cannot update cash asset balances while there are pending investment purchases.");
        uint256 localTotalUSDValue = 0;
        for (uint16 i = 0; i < cashAssets.length; i++) {
            address asset = cashAssets[i];
            IERC20 token = IERC20(asset);
            uint256 tokenBalance = token.balanceOf(address(this));
            require(cashAssetsPrices[asset] != 0, "Asset is missing from the cashAssetsPrices.");
            uint256 balanceInUSDT = Library.priceMulAmount(tokenBalance, token.decimals(), cashAssetsPrices[asset]);
            currentUSDValues[asset] = balanceInUSDT;
            localTotalUSDValue += balanceInUSDT;
        }
        if (cashAssetsAllocations[address(wavax)] == 0) { // Any WAVAX on hand needs to be counted toward the total
            uint256 wavaxBalance = wavax.balanceOf(address(this));
            uint256 wavaxValue = Library.priceMulAmount(wavaxBalance,
                                                        wavax.decimals(),
                                                        cashAssetsPrices[address(wavax)]);
            localTotalUSDValue += wavaxValue;
        }
        totalUSDValue = localTotalUSDValue; // Store it for access in other functions in the future
        uint256 targetUSDValueSum = 0;
        delete liquidationsToPerform;
        delete purchasesToPerform;
        assert(liquidationsToPerform.length == 0);
        assert(purchasesToPerform.length == 0);
        for (uint16 i = 0; i < cashAssets.length; i++) {
            address asset = cashAssets[i];
            // Calculate the target USD value for each cash asset
            uint256 targetPercentage = cashAssetsAllocations[asset];
            uint256 targetUSDValue = Library.percentageOf(localTotalUSDValue, targetPercentage);
            // Set the final one to the remaining total to account for integer division rounding errors
            if (i == (cashAssets.length - 1)) {
                targetUSDValue = localTotalUSDValue - targetUSDValueSum;
            }
            targetUSDValueSum += targetUSDValue;
            targetUSDValues[asset] = targetUSDValue;
            IERC20 token = IERC20(asset);
            uint256 tokenBalance = token.balanceOf(address(this));
            uint256 currentUSDValue = currentUSDValues[asset];
            uint256 currentPercentage = Library.valueIsWhatPercentOf(currentUSDValue, localTotalUSDValue);
            assert(currentPercentage <= ONE_HUNDRED_PERCENT);
            // WAVAX is the asset of purchasing power, so when we have more than we want it will be consumed by purchases
            // When we have less than we want, it will be produced by liquidations
            if (address(asset) == address(wavax)) {
                continue;
            }
            // Record the partial liquidations to process
            // Full liquidations happened in setCashAllocations
            if ((currentUSDValue > 0) &&
                (targetUSDValue < Library.subtractPercentage(currentUSDValue, minimumAllocationDifference))) {
                if ((currentUSDValue - targetUSDValue) < minimumSwapValue) { // Ignore swaps that are too small
                    continue;
                }
                // currentTokenBalance - desiredTokenBalance
                uint256 assetLiquidationAmount = tokenBalance - ((tokenBalance * ONE_HUNDRED_PERCENT * targetPercentage) /
                                                                   (currentPercentage * ONE_HUNDRED_PERCENT));
                assetLiquidationAmounts[asset] = assetLiquidationAmount;
                liquidationsToPerform.push(asset);
            // Record the purchases to do
            } else if (targetUSDValue > Library.addPercentage(currentUSDValue, minimumAllocationDifference)) {
                if ((targetUSDValue - currentUSDValue) < minimumSwapValue) { // Ignore swaps that are too small
                    continue;
                }
                uint256 differenceUSDValue = targetUSDValue - currentUSDValue;
                uint256 assetPurchaseAmount = Library.amountDivPrice(differenceUSDValue, cashAssetsPrices[asset], token.decimals());
                assetPurchaseAmounts[asset] = assetPurchaseAmount;
                purchasesToPerform.push(asset);
            }
        }
        assert(targetUSDValueSum == totalUSDValue); // Something went wrong with the math
        lastCashBalanceUpdateTimestamp = block.timestamp;
    }

    function numLiquidationsToProcess() external view returns (uint256) {
        return liquidationsToPerform.length;
    }

    function numPurhcasesToProcess() external view returns (uint256) {
        return purchasesToPerform.length;
    }

    // Execute a swap to complete a previously stored liquidation
    // This needs to be callable even when paused so that users can redeem their tokens
    function processLiquidation() external { // Anyone can call this
        require(liquidationsToPerform.length > 0,
                "There are no liquidations queued from a call to updateLiquidationsAndPurchases().");
        address asset = liquidationsToPerform[liquidationsToPerform.length - 1];
        require(asset != address(wavax),
                "WAVAX is the asset of purchasing power, it is liquidated merely by purchasing other assets.");
        require(liquidatePaths[asset].length > 0, "Must have a valid lidquidation path to be able to perform a swap.");

        // Set state before external calls
        emit Liquidated(asset);
        liquidationsToPerform.pop();

        address[] memory path = liquidatePaths[asset];
        uint256 desiredAmountToSwap = assetLiquidationAmounts[asset];
        uint256 amountToSwap;
        uint256 expectedReceived;
        (amountToSwap, expectedReceived) = router.findSwapAmountWithinTolerance(path, desiredAmountToSwap, priceImpactTolerance);
        IERC20 fromToken = IERC20(path[0]);
        bool success = fromToken.approve(address(joeRouter), amountToSwap);
        require(success, "token approval failed.");

        // Do the swap
        uint256 minimumReceived = Library.subtractPercentage(expectedReceived, slippageTolerance);
        uint256[] memory amounts = joeRouter.swapExactTokensForTokens(amountToSwap,
                                                                      minimumReceived, // Define a minimum received expectation
                                                                      path,
                                                                      address(this),
                                                                      block.timestamp);
        require(amounts[0] == amountToSwap, "Didn't sell the amount of tokens inserted.");
        require(amounts[amounts.length - 1] >= minimumReceived, "Didn't get out as much as expected.");
    }

    // Execute a swap to complete a previously stored purchase
    function processPurchase() external whenNotPaused { // Anyone can call this
        require(liquidationsToPerform.length == 0,
                "Must complete all liquidations before performing purchases so that capital is on hand.");
        require(purchasesToPerform.length > 0, "There are no purchases queued from a call to updateLiquidationsAndPurchases().");
        address asset = purchasesToPerform[purchasesToPerform.length - 1];
        require(purchasePaths[asset].length > 0, "Must have a valid purchase path to be able to perform a swap.");
        require(purchasePaths[asset][0] == address(wavax), "All purchase paths must start with WAVAX.");
        // Do the swap
        IERC20 fromToken = IERC20(purchasePaths[asset][0]);
        IERC20 toToken = IERC20(asset);
        uint256 desiredAmountOfToken = assetPurchaseAmounts[asset];
        uint256 dollarValue = Library.priceMulAmount(desiredAmountOfToken, toToken.decimals(), cashAssetsPrices[asset]);
        uint256 desiredAmountToSwap = Library.amountDivPrice(dollarValue, cashAssetsPrices[address(fromToken)], fromToken.decimals());
        // It's possible due to rounding errors this might be slightly higher than what I have available
        if (purchasesToPerform.length == 1) {
            desiredAmountToSwap = Math.min(desiredAmountToSwap, fromToken.balanceOf(address(this)));
        }
        // If this is the last purchase and wavax is not in the list of cash assets, then use all remaining wavax
        if ((purchasesToPerform.length == 1) && (cashAssetsAllocations[address(wavax)] == 0)) { // should not have any WAVAX left-over
            desiredAmountToSwap = Math.max(desiredAmountToSwap, fromToken.balanceOf(address(this)));
        }
        // Set state before external calls
        purchasesToPerform.pop();
        emit Purchased(asset);

        address[] memory path = purchasePaths[asset];
        uint256 amountToSwap;
        uint256 expectedReceived;
        (amountToSwap, expectedReceived) = router.findSwapAmountWithinTolerance(path,
                                                                                desiredAmountToSwap,
                                                                                priceImpactTolerance);
        require(amountToSwap <= (wavax.balanceOf(address(this)) - investmentReservedWAVAXAmount),
               "This cash asset purchase would require using WAVAX that is reserved for an investment purchase.");
        bool success = fromToken.approve(address(joeRouter), amountToSwap);
        require(success, "token approval failed.");

        // Do the swap
        // I haven't been able to keep this in SwapRouter because joe only allows doing a swap from the address
        // that's making the call, and I can't use delegate calls with OpenZeppelin upgradeability
        uint256 minimumReceived = Library.subtractPercentage(expectedReceived, slippageTolerance);
        uint256[] memory amounts = joeRouter.swapExactTokensForTokens(amountToSwap,
                                                                      minimumReceived, // Define a minimum received expectation
                                                                      path,
                                                                      address(this),
                                                                      block.timestamp);
        require(amounts[0] == amountToSwap, "Didn't sell the amount of tokens inserted.");
        require(amounts[amounts.length - 1] >= minimumReceived, "Didn't get out as much as expected.");
    }

    // Return the total value of everything in the cash manager denominated in WAVAX
    function totalValueInWAVAX() view public returns (uint256) { // anyone can call this
        uint256 totalValue = 0;
        for (uint16 i = 0; i < cashAssets.length; i++) {
            address asset = cashAssets[i];
            if (asset == address(wavax)) { // don't try to swap WAVAX to WAVAX
                uint256 wavaxBalance = wavax.balanceOf(address(this));
                totalValue += wavaxBalance;
            } else {
                IERC20 token = IERC20(asset);
                uint256 tokenBalance = token.balanceOf(address(this));
                // TODO: This assumes that asset -> wavax exists, but need to use the liquidatePath
                SwapRouter.PriceQuote memory priceInWAVAX = router.getPriceQuote(asset, address(wavax));
                uint256 valueInWAVAX = Library.priceMulAmount(tokenBalance, token.decimals(), priceInWAVAX.price);
                totalValue += valueInWAVAX;
            }
        }
        if (cashAssetsAllocations[address(wavax)] == 0) { // Any WAVAX on hand needs to be counted toward the total
            uint256 wavaxBalance = wavax.balanceOf(address(this));
            totalValue += wavaxBalance;
        }
        return totalValue;
    }

    // Take the amount of WAVAX needed and the current total WAVAX on hand
    // Authorize liquidations to get the total WAVAX on hand up amountNeeded
    // This must be callable when paused so that users can redeem their tokens
    function prepareDryPowder(uint256 amountNeeded, uint256 wavaxOnHand) internal { // only be called by this contract
        // iterate the cash assets, authorizing liquidations until we have enough WAVAX
        // TODO: This iterates through the cashAssets randomly,
        // but I might actually want to do it in order of biggest to smallest?
        for (uint256 i = 0; i < cashAssets.length; i++) {
            address liquidateAsset = cashAssets[i];
            if (liquidateAsset == address(wavax)) { // WAVAX was already included above and doesn't need to be swapped
                continue;
            }
            IERC20 liquidateToken = IERC20(liquidateAsset);
            uint256 liquidateTokenOnHand = liquidateToken.balanceOf(address(this));
            // TODO: This doesn't support multi-hop paths
            SwapRouter.PriceQuote memory priceQuote = router.getPriceQuote(liquidateAsset, address(wavax));
            // Sell only a portion of this one
            uint256 liquidateTokenValueInWAVAX = Library.priceMulAmount(liquidateTokenOnHand,
                                                                        liquidateToken.decimals(),
                                                                        priceQuote.price);
            // Add 1% to make sure we swap enough
            uint256 buyAmountWithCushion = Library.addPercentage(amountNeeded, (1 * (10 ** 6))); 
            if ((liquidateTokenValueInWAVAX + wavaxOnHand) >= buyAmountWithCushion) {
                uint256 differenceNeeded = buyAmountWithCushion - wavaxOnHand;
                uint256 percentLiquidationNeeded = Library.valueIsWhatPercentOf(differenceNeeded, liquidateTokenValueInWAVAX);
                assert(percentLiquidationNeeded < (100 * (10 ** 6)));
                uint256 amountToLiquidate = Library.percentageOf(liquidateTokenOnHand, percentLiquidationNeeded);
                assetLiquidationAmounts[liquidateAsset] = amountToLiquidate;
                wavaxOnHand += differenceNeeded;
                liquidationsToPerform.push(liquidateAsset);
                break; // This one is enough, don't need to continue iterating
            } else { // it's not enough, so add all of it and go to the next
                assetLiquidationAmounts[liquidateAsset] = liquidateTokenOnHand;
                liquidationsToPerform.push(liquidateAsset);
                wavaxOnHand += liquidateTokenValueInWAVAX;
            }
        }
    }

    // Call this before processing a redemption so to authorize any liquidations necessary to get enough WAVAX out
    // This needs to be callable when paused so that users can redeem their tokens
    function prepareDryPowderForRedemption() external {
        uint256 maldenCoinAmount;
        uint256 wavaxAmount;
        (maldenCoinAmount, wavaxAmount) = coin.getAuthorizedRedemptionAmounts(msg.sender);
        require(maldenCoinAmount > 0, "Not authorized to liquidate for redemption.");
        require(wavaxAmount > 0, "Not authorized to liquidate for redemption.");
        uint256 wavaxOnHand = wavax.balanceOf(address(this));
        prepareDryPowder(wavaxAmount, wavaxOnHand);
        // Authorize the coin to take the WAVAX from this contract
        bool success = wavax.approve(address(coin), wavaxAmount); // let the Coin take the WAVAX to give to the user
        require(success, "wavax approval to the MALD coin failed.");
    }

    // Call this before processInvestmentBuy to reserve 
    function prepareDryPowderForInvestmentBuy(address asset) external whenNotPaused { // anyone can call this
        bool exists;
        uint256 buyAmount;
        uint256 buyDeterminationTimestamp;
        bool reservedForBuy;
        uint256 minimumReceived;
        (, , , ,
         buyAmount,
         minimumReceived,
         buyDeterminationTimestamp,
         exists,
         reservedForBuy) = investmentManager.investmentAssetsData(asset);
        // Prevent it from being reserved twice
        require(!reservedForBuy, "asset cannot already be reserved for this purchase.");
        require(exists, "This asset isn't in the investment manager.");
        require(buyAmount > 0, "This asset doesn't have any authorized buy amount.");
        require(block.timestamp < buyDeterminationTimestamp + (24 * 60 * 60)); // A buy determination made over a day ago is invalid
        require(buyAmount <= totalValueInWAVAX(), "Cannot buy with more WAVAX than have on hand.");
        investmentReservedWAVAXAmount += buyAmount;
        // TODO: Authorize liquidations to achieve buyAmount
        uint256 wavaxOnHand = wavax.balanceOf(address(this));
        if (wavaxOnHand < buyAmount) {
            delete liquidationsToPerform;
            assert(liquidationsToPerform.length == 0);
            prepareDryPowder(buyAmount, wavaxOnHand);
        }
        investmentManager.reserveForCashManagerPurchase(asset, buyAmount);
    }

    // Uses cash on hand to make a purchase of a particular asset
    function processInvestmentBuy(address asset) external whenNotPaused { // anyone can call this
        bool exists;
        uint256 buyAmount;
        uint256 buyDeterminationTimestamp;
        bool reservedForBuy;
        uint256 minimumReceived;
        (, , , ,
         buyAmount,
         minimumReceived,
         buyDeterminationTimestamp,
         exists,
         reservedForBuy) = investmentManager.investmentAssetsData(asset);
        require(exists, "This asset isn't in the investment manager.");
        require(buyAmount > 0, "This asset doesn't have any authorized buy amount.");
        require(block.timestamp < buyDeterminationTimestamp + (24 * 60 * 60)); // A buy determination made over a day ago is invalid
        require(minimumReceived > 0, "Must have a minimum received to enforce.");
        // TODO: This constraint could cause issues if the total cash value in WAVAX changed from the time the InvestmentManager was
        // called to the time this is called
        require(buyAmount <= totalValueInWAVAX(), "Cannot buy with more WAVAX than have on hand.");
        require(investmentReservedWAVAXAmount >= buyAmount, "Must have WAVAX reserved for the investment buy.");
        investmentReservedWAVAXAmount -= buyAmount;
        investmentManager.clearBuy(asset, buyAmount);
        if (asset == address(wavax)) { // just send it to the investment manager
            require(wavax.balanceOf(address(this)) >= buyAmount, "Don't have sufficient WAVAX for this buyAmount.");
            bool success = wavax.transfer(address(investmentManager), buyAmount);
            require(success, "WAVAX transfer failed.");
        } else { // swap and send to the InvestmentManager
            bool success = wavax.approve(address(joeRouter), buyAmount);
            require(success, "token approval failed.");

            // Do the swap
            address[] memory path = investmentManager.getBuyPath(asset);
            uint256[] memory amounts = joeRouter.swapExactTokensForTokens(buyAmount,
                                                                          minimumReceived, // Define a minimum received
                                                                          path,
                                                                          address(investmentManager),
                                                                          block.timestamp);
            require(amounts[0] == buyAmount, "Didn't sell the amount of tokens inserted.");
            require(amounts[amounts.length - 1] >= minimumReceived, "Didn't get out as much as expected."); 
        }
    }

    // A convenience function to return what % of total USD portfolio value this asset is, according to the contract
    // Note that the prices are updates potentially every minute by calls to updateCashPrices, whereas
    // the totalUSDValue is updated at most once per day by calls to 
    function assetPercentageOfPortfolio(address asset) external view returns (uint256 value) {
        uint256 priceInUSD = cashAssetsPrices[asset];
        require(priceInUSD > 0, "This asset isn't stored in cash prices.");
        IERC20 token = IERC20(asset);
        uint256 assetValueInUSD = Library.priceMulAmount(token.balanceOf(address(this)), token.decimals(), priceInUSD);
        return Library.valueIsWhatPercentOf(assetValueInUSD, totalUSDValue);
    }
}
