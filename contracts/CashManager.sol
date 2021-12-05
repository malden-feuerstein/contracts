//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
//import "hardhat/console.sol"; // TODO: Remove this for production
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeRouter02.sol";
import "@openzeppelin/contracts/utils/math/Math.sol"; // min()

// local
import "contracts/interfaces/IERC20.sol";
import "contracts/interfaces/ICashManager.sol";
import "contracts/interfaces/IWAVAX.sol";
import "contracts/interfaces/ISwapRouter.sol";
import "contracts/interfaces/IMaldenFeuersteinERC20.sol";
import "contracts/interfaces/IInvestmentManager.sol";
import "contracts/interfaces/IValueHelpers.sol";
import "contracts/Redeemable.sol";
import "contracts/Library.sol";

// Typical usage:
// The owner of CashManager calls setCashAllocations to set the target percentages of each cash asset on hand
// Someone invests AVAX into the MaldenFeuersteinERC20 token by calling invest()
// MaldenFeuersteinERC20 wraps the AVAX into WAVAX and sends it to this CashManager contract
// 1) Anyone calls updateCashPrices() at any time to update the contracts stored prices of each cash asset
// 2) Anyone calls updateLiquidationsAndPurchases() at most once per day to queue up the liquidations and purchases necessary to reach the desired cash asset allocations
// 3) Anyone calls processLiquidation() repeatedly until all queued liquidations are processed.
// 4) After all liquidations are completed, anyone calls processPurchase() repeatedly until all queued purchases are processed.
// 5) If any of the liquidations or purchases were completed only partially because the orders were too big given the price impact requirements, steps 1-4 can be repeated on the following day to move closer to the desired cash allocations.

contract CashManager is OwnableUpgradeable, UUPSUpgradeable, ICashManager, PausableUpgradeable, AccessControlUpgradeable, Redeemable {
    event AddedCashAsset(address);
    event RemovedCashAsset(address);
    event IncreasedCashAsset(address);
    event DecreasedCashAsset(address);
    event Purchased(address); // emitted when an asset is purchased to reach target cash holding percentage

    // Mapping of assets to percentages of USD value to allocate to each, percentages must sum to 100%
    mapping(address => uint256) public cashAssetsAllocations;
    // Mapping of assets to most recent prices in USDT
    mapping(address => uint256) public cashAssetsPrices;
    uint256 public lastCashBalanceUpdateTimestamp;
    uint256 public lastCashAssetsPricesUpdateBlockNumber;
    mapping(address => address[]) private purchasePaths;
    mapping(address => uint256) private targetUSDValues;
    mapping(address => uint256) private currentUSDValues;
    mapping(address => uint256) private assetPurchaseAmounts; // Amount of each token to buy, denominated in token
    address[] purchasesToPerform;
    // Amount of WAVAX reserved for making investment purchases. This amount of WAVAX cannot be used to purchase
    // other cash holdings
    uint256 public investmentReservedWAVAXAmount;

    // contracts
    // some of the contracts are in the Redeemable parent
    IValueHelpers private valueHelpers;
    IInvestmentManager private investmentManager;
    IERC20 private usdt;
    
    // roles
    bytes32 private constant INVESTMENT_MANAGER_ROLE = keccak256("INVESTMENT_MANAGER_ROLE");

    // constants
    // As of this writing average Avalanche C-Chain block time is 2 seconds
    // https://snowtrace.io/chart/blocktime
    uint256 private newBlockEveryNMicroseconds;
    uint256 public totalUSDValue;
    uint256 private minimumSwapValue;
    uint256 private minimumAllocationDifference; // minimum percentage allocation must differ to queue a swap for it

    function initialize() external virtual initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        __AccessControl_init();
        lastCashBalanceUpdateTimestamp = 0;
        lastCashAssetsPricesUpdateBlockNumber = 0;
        newBlockEveryNMicroseconds = 2000;
        totalUSDValue = 0;
        priceImpactTolerance = 1 * (10 ** 6); // 1%
        minimumAllocationDifference = 1 * (10 ** 6); // 1%
        minimumSwapValue = 50 * (10 ** 6); // $50
        slippageTolerance = 5 * (10 ** 6) / 10; // 0.5%
        investmentReservedWAVAXAmount = 0;
        managerChoice = ManagerChoice.CashManager;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setAddresses(address localWAVAXAddress,
                          address joeRouterAddress,
                          address swapRouterAddress,
                          address coinAddress,
                          address valueHelpersAddress,
                          address investmentManagerAddress,
                          address usdtAddress) external onlyOwner whenNotPaused {
        require(localWAVAXAddress != address(0));
        wavaxAddress = localWAVAXAddress;
        wavax = IWAVAX(localWAVAXAddress);
        joeRouter = IJoeRouter02(joeRouterAddress);
        swapRouter = ISwapRouter(swapRouterAddress);
        coin = IMaldenFeuersteinERC20(coinAddress);
        valueHelpers = IValueHelpers(valueHelpersAddress);
        investmentManager = IInvestmentManager(investmentManagerAddress);
        _setupRole(INVESTMENT_MANAGER_ROLE, investmentManagerAddress);
        usdt = IERC20(usdtAddress);
    }

    function pause() external whenNotPaused onlyOwner {
        _pause();
    }

    function unpause() external whenPaused onlyOwner {
        _unpause();
    }

    // Owner tells the contract to change how it holds "cash" prior to investing it
    // This liquidates any holdings that were previously in the assets and were removed
    // TODO: Test calling this with very long list of assets. How large does it need to be to hit the gas limit due to these
    //    for loops over dynamic arrays?
    function setCashAllocations(address[] calldata localAssets,
                                uint256[] calldata percentages,
                                address[][] calldata passedLiquidatePaths,
                                address[][] calldata passedPurchasePaths) external onlyOwner whenNotPaused {
        require(localAssets.length < 50, "Can not have more than 50 cash assets."); // This prevents issues with loops and gas
        require(localAssets.length == percentages.length, "Assets and percentages arrays must be the same length.");
        // TODO: I need these to be uncommented when I get this contract within the size limit
        require(passedLiquidatePaths.length == localAssets.length, "Must have a liquidatePath for each asset.");
        require(passedPurchasePaths.length == localAssets.length, "Must have a purchasePath for each asset.");
        uint sum = 0;
        for(uint i = 0; i < percentages.length; i++) {
            require(percentages[i] > 0, "Can't assign a cash asset to a portfolio weight of 0%.");
            sum += percentages[i];
        }
        require(sum == Library.ONE_HUNDRED_PERCENT, "The percentages must sum to 100%.");

        address[] memory oldAssets = assets;
        delete assets; // reset
        assert(assets.length == 0); // make sure the array is starting over
        for (uint i = 0; i < oldAssets.length; i++) { // reset the mapping
            cashAssetsAllocations[oldAssets[i]] = 0;
        }
        for (uint i = 0; i < localAssets.length; i++) { // assign the new values
            address asset = localAssets[i];
            assets.push(asset);
            cashAssetsAllocations[asset] = percentages[i];
            liquidatePaths[asset] = passedLiquidatePaths[i];
            // All purchases start in WAVAX currently
            if (asset != wavaxAddress) {
                require(passedPurchasePaths[i][0] == wavaxAddress, "All purchase paths must begin with WAVAX.");
                require(passedLiquidatePaths[i][passedLiquidatePaths[i].length - 1] == wavaxAddress,
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
                    if (asset != wavaxAddress) { // WAVAX is the liquidated asset temprary holding
                        // Set state before external calls
                        emit Liquidated(asset);
                        uint256 desiredAmountToSwap = token.balanceOf(address(this));
                        address[] memory path = liquidatePaths[asset];
                        uint256 amountToSwap;
                        uint256 expectedReceived;
                        (amountToSwap, expectedReceived) = swapRouter.findSwapAmountWithinTolerance(path,
                                                                                                    desiredAmountToSwap,
                                                                                                    priceImpactTolerance);
                        // If not fully liquidating it, then keep it in the asset list to process further liquidations
                        if (amountToSwap != desiredAmountToSwap) {
                            assets.push(asset);
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
        Library.PriceQuote memory wavaxInUSDTQuote = swapRouter.getPriceQuote(address(wavax), address(usdt));
        if (cashAssetsPrices[address(wavax)] > 0) {
            // TODO: Owner should be able to change this 10x factor
            require(wavaxInUSDTQuote.price < cashAssetsPrices[address(wavax)] * 10,
                    "Price going up more than 10x, something is wrong.");
            require(wavaxInUSDTQuote.price > cashAssetsPrices[address(wavax)] / 10,
                   "Price going down by more than 10x, something is wrong.");
        }
        cashAssetsPrices[address(wavax)] = wavaxInUSDTQuote.price;

        uint8 wavax_decimals = wavax.decimals();
        for (uint32 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            if (asset == address(usdt)) {
                cashAssetsPrices[asset] = 10 ** usdt.decimals(); // USDT:USDT is 1:1 definitionally
            } else if (asset != address(wavax)) { // WAVAX price was already updated
                // First convert to WAVAX, then convert to USDT
                Library.PriceQuote memory quoteInWAVAX = swapRouter.getPriceQuote(asset, address(wavax));
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
        require(block.timestamp > lastCashBalanceUpdateTimestamp + 86400, "Can update cash balances only once per day.");
        // Speed bump: https://samczsun.com/so-you-want-to-use-a-price-oracle/
        require(block.number > lastCashAssetsPricesUpdateBlockNumber, "Cannot update prices and balances in the same block.");
        require(block.number < lastCashAssetsPricesUpdateBlockNumber + ((60 * 1000) / newBlockEveryNMicroseconds),
                "Cash asset prices are older than one minute.");
        require(investmentReservedWAVAXAmount == 0,
                "Cannot update cash asset balances while there are pending investment purchases.");
        uint256 localTotalUSDValue = 0;
        for (uint16 i = 0; i < assets.length; i++) {
            address asset = assets[i];
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
        for (uint16 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            // Calculate the target USD value for each cash asset
            uint256 targetPercentage = cashAssetsAllocations[asset];
            uint256 targetUSDValue = Library.percentageOf(localTotalUSDValue, targetPercentage);
            // Set the final one to the remaining total to account for integer division rounding errors
            if (i == (assets.length - 1)) {
                targetUSDValue = localTotalUSDValue - targetUSDValueSum;
            }
            targetUSDValueSum += targetUSDValue;
            targetUSDValues[asset] = targetUSDValue;
            IERC20 token = IERC20(asset);
            uint256 tokenBalance = token.balanceOf(address(this));
            uint256 currentUSDValue = currentUSDValues[asset];
            uint256 currentPercentage = Library.valueIsWhatPercentOf(currentUSDValue, localTotalUSDValue);
            assert(currentPercentage <= Library.ONE_HUNDRED_PERCENT);
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
                uint256 assetLiquidationAmount = tokenBalance - ((tokenBalance * Library.ONE_HUNDRED_PERCENT * targetPercentage) /
                                                                   (currentPercentage * Library.ONE_HUNDRED_PERCENT));
                assetLiquidationAmounts[asset] = assetLiquidationAmount;
                if (assetLiquidationAmount > 0) {
                    liquidationsToPerform.push(asset);
                }
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

    function numPurhcasesToProcess() external view returns (uint256) {
        return purchasesToPerform.length;
    }

    // Execute a swap to complete a previously stored purchase
    function processPurchase() external whenNotPaused { // Anyone can call this
        require(liquidationsToPerform.length == 0,
                "Must complete all liquidations before performing purchases so that capital is on hand.");
        require(purchasesToPerform.length > 0, "There are no purchases queued from a call to updateLiquidationsAndPurchases().");
        address asset = purchasesToPerform[purchasesToPerform.length - 1];
        require(purchasePaths[asset].length > 0, "Must have a valid purchase path to be able to perform a swap.");
        require(purchasePaths[asset][0] == wavaxAddress, "All purchase paths must start with WAVAX.");
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
        // should not have any WAVAX left-over
        if ((purchasesToPerform.length == 1) && (cashAssetsAllocations[wavaxAddress] == 0)) {
            desiredAmountToSwap = Math.max(desiredAmountToSwap, fromToken.balanceOf(address(this)));
        }
        // Set state before external calls
        purchasesToPerform.pop();
        emit Purchased(asset);

        address[] memory path = purchasePaths[asset];
        uint256 amountToSwap;
        uint256 expectedReceived;
        (amountToSwap, expectedReceived) = swapRouter.findSwapAmountWithinTolerance(path,
                                                                                    desiredAmountToSwap,
                                                                                    priceImpactTolerance);
        // FIXME: The fuzzer is getting into situations where investmentReservedWAVAXAmount > wavax.balanceOf(this)
        // This is possible when multiple buy determinations are made before the previous buy determinations have been
        // processed.
        require(amountToSwap <= (wavax.balanceOf(address(this)) - investmentReservedWAVAXAmount),
               "This cash asset purchase would require using WAVAX that is reserved for an investment purchase.");
        bool success = fromToken.approve(address(joeRouter), amountToSwap);
        require(success, "token approval failed.");

        // Do the swap
        // I haven't been able to keep this in SwapRouter because joe only allows doing a swap from the address
        // that's making the call, and I can't use delegate calls with OpenZeppelin upgradeability
        uint256 minimumReceived = Library.subtractPercentage(expectedReceived, slippageTolerance);
        // Define a minimum received expectation
        uint256[] memory amounts = joeRouter.swapExactTokensForTokens(amountToSwap,
                                                                      minimumReceived, 
                                                                      path,
                                                                      address(this),
                                                                      block.timestamp);
        require(amounts[0] == amountToSwap, "Didn't sell the amount of tokens inserted.");
        require(amounts[amounts.length - 1] >= minimumReceived, "Didn't get out as much as expected.");
    }

    // Call this before InvestmentManager.processBuy to prepare liquidations to have enough WAVAX to make an investment
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
        require(exists, "CashManager: exists"); // This asset isn't in the investment manager.
        require(buyAmount > 0, "This asset doesn't have any authorized buy amount.");
        require(block.timestamp <= buyDeterminationTimestamp + (24 * 60 * 60), "A buy determination made over a day ago is invalid");
        require(buyAmount <= valueHelpers.cashManagerTotalValueInWAVAX(),
                "Cannot buy with more WAVAX than have on hand.");
        investmentReservedWAVAXAmount += buyAmount;
        // TODO: Authorize liquidations to achieve buyAmount
        uint256 wavaxOnHand = wavax.balanceOf(address(this));
        if (wavaxOnHand < buyAmount) {
            // TODO: It's possible for this to delete liquidations queued from a previous operation,
            // such as a redemption or an investment buy
            delete liquidationsToPerform;
            assert(liquidationsToPerform.length == 0);
            prepareDryPowder(buyAmount, wavaxOnHand);
        }
        bool success = wavax.approve(address(investmentManager), buyAmount);
        require(success, "WAVAX approval failed.");
        investmentManager.reserveForCashManagerPurchase(asset, buyAmount);
    }

    function clearInvestmentReservation(uint256 buyAmount) external whenNotPaused {
        require(hasRole(INVESTMENT_MANAGER_ROLE, msg.sender), "Caller is not an InvestmentManager.");
        require(investmentReservedWAVAXAmount >= buyAmount, "Cannot clear more than currently reserved.");
        investmentReservedWAVAXAmount -= buyAmount;
    }

}
