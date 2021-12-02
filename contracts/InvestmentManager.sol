//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "hardhat/console.sol"; // TODO: Remove this for production
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeRouter02.sol";
import "@openzeppelin/contracts/utils/math/Math.sol"; // min()

// local
import "contracts/IERC20.sol";
import "contracts/SwapRouter.sol";
import "contracts/Library.sol";
import "contracts/ICashManager.sol";

// Typical Usage to make an investment (buy):
// Call setInvestmentAsset() to create a list of assets to invest in
// Call getLatestPrice() every week on each asset to store for future reference
// Call determineBuy() to determine if an asset is ready to be purchase based on value investment principles
// Call CashManager.prepareDryPowderForInvestmentBuy() to reserve sufficient WAVAX and authorize liquidations to WAVAX
// Call CashManager.processLiquidation() in a loop to process any liquidations necessary to have sufficient WAVAX on hand
// Call CashManager.processInvestmentBuy() to use its cash to make the investment

// Typical usage to liquidate an investment (sell):
// Call determineSell() to determine if the criteria for selling an asset have been met
// TODO: Call processSell() to perform determined sells and send the WAVAX to the CashManager

contract InvestmentManager is OwnableUpgradeable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
    event DeterminedBuy(address, uint256, uint256); // address of asset to  buy, amount to buy, kelly fraction
    struct InvestmentAsset {
      address assetAddress;
      uint256 intrinsicValue; // intrinsive value estimate in USDT
      address[] liquidatePath;
      address[] purchasePath;
      uint256[] prices;
      uint256[] priceTimestamps;
      uint256 confidence; // probability of success in micro percentage points
      uint256 sellAmount;
      uint256 buyAmount; // Amount of WAVAX to swap for a purchase, slippage already taken into account
      uint256 minimumReceived;
      uint256 buyDeterminationTimestamp; // timestamp of when the buy amount was determined
      bool exists;
      bool reservedForBuy;
    }
    // contracts
    SwapRouter private router;
    IWAVAX private wavax;
    IERC20 private usdt;
    IJoeRouter02 private joeRouter; // TODO: this should probably be set on construction
    IJoeFactory private joeFactory;
    address private cashManagerAddress;
    bytes32 public constant CASH_MANAGER_ROLE = keccak256("CASH_MANAGER_ROLE");

    // constants
    // As of this writing average Avalanche C-Chain block time is 2 seconds
    // https://snowtrace.io/chart/blocktime
    uint256 private newBlockEveryNMicroseconds;
    uint256 private minimumSwapValue;
    uint256 private priceImpactTolerance; // price impact micro percentage
    uint256 private priceUpdateInterval; // minimum number of seconds to pass between asset price updates
    uint8 private nWeeksOfScorn; // If an asset has been falling in price or stable in price for the past n weeks, then it's a buy
    uint256 private marginOfSafety; // percentage under intrinsic value an asset must be to warrant a buy
    uint256 private slippageTolerance;

    // investment storage
    address[] public investmentAssets; // A list of the assets for potential investment
    mapping(address => InvestmentAsset) public investmentAssetsData; // mapping investmentAssets -> intrinsic value
    uint16 numBuysAuthorized;

    function initialize(address swapRouterAddress) external virtual initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        require(swapRouterAddress != address(0), "Cannot set the swap router to the null address.");
        newBlockEveryNMicroseconds = 2000;
        priceImpactTolerance = 1 * (10 ** 6); // This is one micro percent, or 1 percent with 6 decimals
        wavax = IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
        usdt = IERC20(0xc7198437980c041c805A1EDcbA50c1Ce5db95118);
        minimumSwapValue = 50 * (10 ** usdt.decimals()); // Don't bother swapping less than $50
        router = SwapRouter(swapRouterAddress);
        joeRouter = IJoeRouter02(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
        joeFactory = IJoeFactory(0x9Ad6C38BE94206cA50bb0d90783181662f0Cfa10);
        priceUpdateInterval = 24 * 60 * 60 * 7; // one week
        numBuysAuthorized = 0;
        nWeeksOfScorn = 4;
        slippageTolerance = 5 * (10 ** 6) / 10; // 0.5%
        marginOfSafety = 25 * (10 ** 6);
    }

    function _authorizeUpgrade(address) internal override onlyOwner whenNotPaused {}

    function pause() external whenNotPaused onlyOwner {
        _pause();
    }

    function unpause() external whenPaused onlyOwner {
        _unpause();
    }

    function setCashManagerAddress(address localCashManagerAddress) external onlyOwner whenNotPaused {
        require(localCashManagerAddress != address(0), "Cannot set the cashManager to the null address.");
        cashManagerAddress = localCashManagerAddress;
        _setupRole(CASH_MANAGER_ROLE, cashManagerAddress);
    }

    // Set the intrinsic value for a particular asset
    // If the asset is already in the list of tracked assets, update the intrinsic value
    // If the asset is not already in the list of tracked assets, add it to the list
    function setInvestmentAsset(address asset,
                                uint256 intrinsicValue, // In USDT
                                uint256 confidence, // In micro percentage points
                                address[] calldata liquidatePath,
                                address[] calldata purchasePath) external onlyOwner whenNotPaused { // only owner can call this
        // All buys begin with WAVAX and all sells end with WAVAX
        if (asset != address(wavax)) {
            require(liquidatePath[liquidatePath.length - 1] == address(wavax));
            require(purchasePath[0] == address(wavax));
        }
        require(confidence > 0, "Cannot have 0 confidence.");
        require(confidence <= 100 * (10 ** 6), "Cannot be more than 100% confident.");
        require(intrinsicValue > 0, "Cannot have 0 intrinsicValue.");
        if (investmentAssetsData[asset].exists) { // Already there, update values
            assert(investmentAssetsData[asset].assetAddress == asset);
            investmentAssetsData[asset].intrinsicValue = intrinsicValue;
            investmentAssetsData[asset].liquidatePath = liquidatePath;
            investmentAssetsData[asset].purchasePath = purchasePath;
        } else { // Not there already, add it
            uint256[] memory emptyArray;
            InvestmentAsset memory newAsset = InvestmentAsset(asset,
                                                              intrinsicValue,
                                                              liquidatePath,
                                                              purchasePath,
                                                              emptyArray,
                                                              emptyArray,
                                                              confidence,
                                                              0,
                                                              0,
                                                              0,
                                                              0,
                                                              true,
                                                              false);
            investmentAssetsData[asset] = newAsset;
            investmentAssets.push(asset);
        }
    }

    // Store the latest price for a particular investment asset
    function getLatestPrice(address asset) external whenNotPaused { // anyone can call this
        require(investmentAssetsData[asset].exists, "asset is not in the chosen list of investmentAssets.");
        assert(investmentAssetsData[asset].prices.length == investmentAssetsData[asset].priceTimestamps.length);

        // Assert that the most recent price wasn't too recent
        if (investmentAssetsData[asset].prices.length > 0) {
            uint256 latestPriceTimestamp = investmentAssetsData[asset].priceTimestamps[
                investmentAssetsData[asset].priceTimestamps.length - 1];
            require(latestPriceTimestamp <= block.timestamp - priceUpdateInterval, "Can update price at most once per week.");
        }

        SwapRouter.PriceQuote memory price = router.getPriceQuote(asset, address(usdt));
        investmentAssetsData[asset].prices.push(price.price);
        investmentAssetsData[asset].priceTimestamps.push(block.timestamp);
    }

    // Determine if the situation is right for a particular asset to be sold
    // If so, record it so that processSell() can sell it
    // TODO: Are there any issues with someone being able to call this at any time?
    function determineSell(address asset) external whenNotPaused { // anyone can call this at any time
        require(investmentAssetsData[asset].exists, "asset is not in the chosen list of investmentAssets.");
        // TODO: I don't want to assume that asset -> usdt exists directly, need to use liquidatePath
        SwapRouter.PriceQuote memory currentPrice = router.getPriceQuote(asset, address(usdt));
        // Sell when an asset is 50% above the intrinsicValue
        if (currentPrice.price > Library.addPercentage(investmentAssetsData[asset].intrinsicValue,
                                                 50 * (10 ** 6))) { // 50% more than intrinsicValue
            // Sell all of it. Is this always what I want this to do here? What about partial sells?
            investmentAssetsData[asset].sellAmount = IERC20(asset).balanceOf(address(this));
            investmentAssetsData[asset].buyAmount = 0; // reset value
        }
        // TODO: A sell is also when there is another bet that is a far better opportunity
    }

    // Based on value investment principles using historical prices and the owner-given intrinsicValue, 
    // this determines when the market is in a situation to warrant a buy of a particular asset
    // If this function determines a buy, it sets a variable in this contract that authorizes the CashManager to send
    // WAVAX to this contract to give it purchasing power
    // With the Kelly bet here we want to be rougly right rather than exactly wrong
    // Will place fractional Kelly bets
    function determineBuy(address asset) external whenNotPaused { // anyone can call this
        require(investmentAssetsData[asset].exists, "asset is not in the chosen list of investmentAssets.");
        require(investmentAssetsData[asset].sellAmount == 0, "cannot buy asset if sell is pending.");
        require(investmentAssetsData[asset].prices.length >= nWeeksOfScorn, "Must have a minimum number of price samples.");
        // Total value of what the CashManager is holding, denominated in WAVAX
        uint256 totalCashValue = ICashManager(cashManagerAddress).totalValueInWAVAX();
        //console.log("Got total cash value in WAVAX of %s", totalCashValue);
        // TODO: I don't want to assume that asset -> usdt path exists directly, need to use liquidate path
        SwapRouter.PriceQuote memory currentPrice = router.getPriceQuote(asset, address(usdt));
        //console.log("Asset current price: %s", currentPrice.price);
        // A buy is when an asset is at least 25% below its intrinsicValue
        if (currentPrice.price < Library.subtractPercentage(investmentAssetsData[asset].intrinsicValue, marginOfSafety)) {
            // TODO: Check if it is stable in price over the past n weeks (+/- 10%)
            // TODO: The loss should probably be a paramter on the individual asset
            // Calculate the amount won in the success scenario off of the intrinsic value number
            uint256 percentGainExpected = Library.valueIsWhatPercentOf(investmentAssetsData[asset].intrinsicValue -currentPrice.price,
                                                                       currentPrice.price);
            //console.log("Expecting a gain of %s in the success scenario", percentGainExpected);
            uint256 kellyFraction = Library.kellyFraction(investmentAssetsData[asset].confidence,
                                                          (80 * (10 ** 6)), // lose 80%
                                                          percentGainExpected); // Double in win scenario
            //console.log("raw kelly fraction of %s", kellyFraction);
            kellyFraction /= 2; // Take half kelly bet
            kellyFraction = Math.min(kellyFraction, 100 * (10 ** 6)); // Can't take more than 100% of available funds
            uint256 betSize = Library.percentageOf(totalCashValue, kellyFraction); // half kelly bet in WAVAX
            // Now modify the betSize based on the AMM market conditions and slippage tolerances
            uint256 expectedReceived;
            uint256 minimumReceived;
            if (asset != address(wavax)) {
                require(investmentAssetsData[asset].purchasePath[0] == address(wavax), "Purchase paths must start with WAVAX.");
                (betSize, expectedReceived) = router.findSwapAmountWithinTolerance(investmentAssetsData[asset].purchasePath,
                                                                                        betSize,
                                                                                        priceImpactTolerance);
                minimumReceived = Library.subtractPercentage(expectedReceived, slippageTolerance);
            } else { // if I'm just sending WAVAX then I should receive the exact amount
                minimumReceived = betSize;
            }
            //console.log("betSize %s", betSize);
            investmentAssetsData[asset].buyAmount = betSize; // in WAVAX
            investmentAssetsData[asset].buyDeterminationTimestamp = block.timestamp;
            investmentAssetsData[asset].minimumReceived = minimumReceived;
            emit DeterminedBuy(asset, betSize, kellyFraction);
        }
    }

    function getBuyPath(address asset) view external returns (address[] memory) { // anyone can call this
        require(investmentAssetsData[asset].exists);
        return investmentAssetsData[asset].purchasePath;
    }

    // Allow the CashManager to decrease the buy amount after making a purchase
    function clearBuy(address asset, uint256 boughtAmount) external whenNotPaused {
        require(hasRole(CASH_MANAGER_ROLE, msg.sender), "Caller is not a CashManager");
        require(boughtAmount <= investmentAssetsData[asset].buyAmount, "Cannot reduce buyAmount by more than it is.");
        investmentAssetsData[asset].buyAmount = 0;
        investmentAssetsData[asset].reservedForBuy = false;
        investmentAssetsData[asset].minimumReceived = 0;
    }

    function reserveForCashManagerPurchase(address asset, uint256 buyAmount) external whenNotPaused {
        require(hasRole(CASH_MANAGER_ROLE, msg.sender), "Caller is not a CashManager");
        require(investmentAssetsData[asset].exists, "Asset must be in investments lists.");
        require(investmentAssetsData[asset].buyAmount > 0, "Must have a determined buyAmount.");
        require(!investmentAssetsData[asset].reservedForBuy, "Must not already be reserved for buy.");
        require(investmentAssetsData[asset].buyAmount == buyAmount, "Must reserve the amount determined.");
        investmentAssetsData[asset].reservedForBuy = true;
    }

    function processSell() external whenNotPaused { // anyone can call this
        // TODO: A sell is invalid if it's older than a day
        // TODO: If selling WAVAX, just transfer is to the CashManager without doing a swap
    }

    // If there are no buys to perform, this authorizes the CashManager to take back any excess WAVAX
    // TODO: Nothing is calling this - should it be here?
    function drainExtraCash() external whenNotPaused { // anyone can call this
        // TODO: Prevent this from intefering with other calls by requiring a 1 hour wait after any call to
        // determineSell, determineBuy, or setInvestmentAsset
        require(cashManagerAddress != address(0), "The cashManagerAddress has not been set yet.");
        if (numBuysAuthorized == 0) {
            require(wavax.allowance(address(this), cashManagerAddress) == 0, "Must start from 0 allowance to set allowance.");
            bool success = wavax.approve(cashManagerAddress, wavax.balanceOf(address(this)));
            require(success, "Approving the CashManager to take WAVAX failed.");
        }
    }

    // Return the total value of everything in the cash manager denominated in WAVAX
    // TODO: This is a near duplicate of the same function in the CashManager. Ideally I wouldn't have this code duplication,
    // but I'm unable to solve it because OpenZeppelin's upgradeability doesn't allow Library functions that modify state, nor
    // the use of delegatecall
    function totalValueInWAVAX() view external returns (uint256) { // anyone can call this
        uint256 totalValue = 0;
        for (uint16 i = 0; i < investmentAssets.length; i++) {
            address asset = investmentAssets[i];
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
        return totalValue;
    }
}
