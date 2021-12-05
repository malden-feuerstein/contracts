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
import "contracts/interfaces/IERC20.sol";
import "contracts/Library.sol";
import "contracts/interfaces/IInvestmentManager.sol";
import "contracts/interfaces/IWAVAX.sol";
import "contracts/interfaces/IValueHelpers.sol";
import "contracts/interfaces/ICashManager.sol";
import "contracts/Redeemable.sol";

// Typical Usage to make an investment (buy):
// Call setInvestmentAsset() to create a list of assets to invest in
// Call getLatestPrice() every week on each asset to store for future reference
// Call determineBuy() to determine if an asset is ready to be purchase based on value investment principles
// Call CashManager.prepareDryPowderForInvestmentBuy() to reserve sufficient WAVAX and authorize liquidations to WAVAX
// Call CashManager.processLiquidation() in a loop to process any liquidations necessary to have sufficient WAVAX on hand
// processBuy() to use its cash to make the investment

// Typical usage to liquidate an investment (sell):
// Call determineSell() to determine if the criteria for selling an asset have been met
// TODO: Call processSell() to perform determined sells and send the WAVAX to the CashManager

contract InvestmentManager is OwnableUpgradeable,
                              UUPSUpgradeable,
                              AccessControlUpgradeable,
                              PausableUpgradeable,
                              IInvestmentManager,
                              Redeemable {
    event DeterminedBuy(address, uint256, uint256); // address of asset to buy, amount to buy, kelly fraction

    bytes32 private constant CASH_MANAGER_ROLE = keccak256("CASH_MANAGER_ROLE");

    // contracts
    IERC20 private usdt;
    IValueHelpers private valueHelpers;
    ICashManager private cashManager;

    // constants
    // As of this writing average Avalanche C-Chain block time is 2 seconds
    // https://snowtrace.io/chart/blocktime
    uint256 private newBlockEveryNMicroseconds;
    uint256 private minimumSwapValue;
    uint256 private priceUpdateInterval; // minimum number of seconds to pass between asset price updates
    uint8 private nWeeksOfScorn; // If an asset has been falling in price or stable in price for the past n weeks, then it's a buy
    uint256 private marginOfSafety; // percentage under intrinsic value an asset must be to warrant a buy

    // investment storage
    mapping(address => InvestmentAsset) public investmentAssetsData; // mapping assets -> intrinsic value
    uint16 numBuysAuthorized;

    function initialize() external virtual initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        newBlockEveryNMicroseconds = 2000;
        priceImpactTolerance = 1 * (10 ** Library.PERCENTAGE_DECIMALS); // This is one micro percent, or 1 percent with 6 decimals
        minimumSwapValue = 50 * (10 ** 6); // Don't bother swapping less than $50, this is USDT decimals
        priceUpdateInterval = 24 * 60 * 60 * 7; // one week
        numBuysAuthorized = 0;
        nWeeksOfScorn = 4;
        slippageTolerance = (5 * (10 ** Library.PERCENTAGE_DECIMALS)) / 10; // 0.5%
        marginOfSafety = 25 * (10 ** Library.PERCENTAGE_DECIMALS); // 25%
        managerChoice = ManagerChoice.InvestmentManager;
    }

    function _authorizeUpgrade(address) internal override onlyOwner whenNotPaused {}

    function setAddresses(address localWAVAXAddress,
                          address swapRouterAddress,
                          address valueHelpersAddress,
                          address usdtAddress,
                          address cashManagerAddress,
                          address joeRouterAddress,
                          address coinAddress) external onlyOwner whenNotPaused {
        require(localWAVAXAddress != address(0));
        wavaxAddress = localWAVAXAddress;
        wavax = IWAVAX(wavaxAddress);
        usdt = IERC20(usdtAddress);
        swapRouter = ISwapRouter(swapRouterAddress);
        valueHelpers = IValueHelpers(valueHelpersAddress);
        cashManager = ICashManager(cashManagerAddress);
        _setupRole(CASH_MANAGER_ROLE, cashManagerAddress);
        joeRouter = IJoeRouter02(joeRouterAddress);
        coin = IMaldenFeuersteinERC20(coinAddress);
    }

    function pause() external whenNotPaused onlyOwner {
        _pause();
    }

    function unpause() external whenPaused onlyOwner {
        _unpause();
    }

    // Set the intrinsic value for a particular asset
    // If the asset is already in the list of tracked assets, update the intrinsic value
    // If the asset is not already in the list of tracked assets, add it to the list
    // TODO: As it stands currently an asset can not be removed once added, it can only be modified
    function setInvestmentAsset(address asset,
                                uint256 intrinsicValue, // In USDT
                                uint256 confidence, // In micro percentage points
                                address[] calldata liquidatePath,
                                address[] calldata purchasePath) external onlyOwner whenNotPaused { // only owner can call this
        // All buys begin with WAVAX and all sells end with WAVAX
        if (asset != wavaxAddress) {
            require(liquidatePath[liquidatePath.length - 1] == wavaxAddress);
            require(purchasePath[0] == wavaxAddress);
        }
        require(confidence > 0, "Cannot have 0 confidence.");
        require(confidence <= Library.ONE_HUNDRED_PERCENT, "Cannot be more than 100% confident.");
        require(intrinsicValue > 0, "Cannot have 0 intrinsicValue.");
        if (investmentAssetsData[asset].exists) { // Already there, update values
            assert(investmentAssetsData[asset].assetAddress == asset);
            investmentAssetsData[asset].intrinsicValue = intrinsicValue;
            // This is not a part of the InvestmentAsset struct so that it's compatible with Redeemable
            liquidatePaths[asset] = liquidatePath;
            investmentAssetsData[asset].purchasePath = purchasePath;
        } else { // Not there already, add it
            uint256[] memory emptyArray;
            liquidatePaths[asset] = liquidatePath;
            InvestmentAsset memory newAsset = InvestmentAsset(asset,
                                                              intrinsicValue,
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
            assets.push(asset);
        }
    }

    // Store the latest price for a particular investment asset
    function getLatestPrice(address asset) external whenNotPaused { // anyone can call this
        require(investmentAssetsData[asset].exists, "asset is not in the chosen list of assets.");
        assert(investmentAssetsData[asset].prices.length == investmentAssetsData[asset].priceTimestamps.length);

        // Assert that the most recent price wasn't too recent
        if (investmentAssetsData[asset].prices.length > 0) {
            uint256 latestPriceTimestamp = investmentAssetsData[asset].priceTimestamps[
                investmentAssetsData[asset].priceTimestamps.length - 1];
            require(latestPriceTimestamp <= block.timestamp - priceUpdateInterval, "Can update price at most once per week.");
        }

        Library.PriceQuote memory price = swapRouter.getPriceQuote(asset, address(usdt));
        investmentAssetsData[asset].prices.push(price.price);
        investmentAssetsData[asset].priceTimestamps.push(block.timestamp);
    }

    // Determine if the situation is right for a particular asset to be sold
    // If so, record it so that processSell() can sell it
    // TODO: Are there any issues with someone being able to call this at any time?
    function determineSell(address asset) external whenNotPaused { // anyone can call this at any time
        require(investmentAssetsData[asset].exists, "asset is not in the chosen list of assets.");
        // TODO: I don't want to assume that asset -> usdt exists directly, need to use liquidatePath
        Library.PriceQuote memory currentPrice = swapRouter.getPriceQuote(asset, address(usdt));
        // Sell when an asset is 50% above the intrinsicValue
        if (currentPrice.price > Library.addPercentage(investmentAssetsData[asset].intrinsicValue,
                                                 50 * (10 ** Library.PERCENTAGE_DECIMALS))) { // 50% more than intrinsicValue
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
        require(investmentAssetsData[asset].exists, "asset is not in the chosen list of assets.");
        require(investmentAssetsData[asset].sellAmount == 0, "cannot buy asset if sell is pending.");
        require(investmentAssetsData[asset].prices.length >= nWeeksOfScorn, "Must have a minimum number of price samples.");
        require(!investmentAssetsData[asset].reservedForBuy, "Cannot determine a buy on an asset currently reserved for buy.");
        // Total value of what the CashManager is holding, denominated in WAVAX
        uint256 totalCashValue = valueHelpers.cashManagerTotalValueInWAVAX();
        //console.log("Got total cash value in WAVAX of %s", totalCashValue);
        // TODO: I don't want to assume that asset -> usdt path exists directly, need to use liquidate path
        Library.PriceQuote memory currentPrice = swapRouter.getPriceQuote(asset, address(usdt));
        //console.log("Asset current price: %s", currentPrice.price);
        // A buy is when an asset is at least 25% below its intrinsicValue
        if (currentPrice.price < Library.subtractPercentage(investmentAssetsData[asset].intrinsicValue, marginOfSafety)) {
            // TODO: Check if it is stable in price over the past n weeks (+/- 10%)
            // Calculate the amount won in the success scenario off of the intrinsic value number
            uint256 percentGainExpected = Library.valueIsWhatPercentOf(
                                                                    investmentAssetsData[asset].intrinsicValue - currentPrice.price,
                                                                    currentPrice.price);
            // TODO: The expected loss should probably be a paramter on the individual asset
            uint256 kellyFraction = Library.kellyFraction(investmentAssetsData[asset].confidence,
                                                          (80 * (10 ** Library.PERCENTAGE_DECIMALS)), // lose 80%
                                                          percentGainExpected); // Double in win scenario
            kellyFraction /= 2; // Take half kelly bet
            kellyFraction = Math.min(kellyFraction, Library.ONE_HUNDRED_PERCENT); // Can't take more than 100% of available funds
            // FIXME: The betSize should have subtracted the value of the current holdings of the asset
            // FIXME: betSize should be >0 only if the current holding is more than 1% off from the target
            uint256 betSize = Library.percentageOf(totalCashValue, kellyFraction); // half kelly bet in WAVAX
            // Now modify the betSize based on the AMM market conditions and slippage tolerances
            uint256 expectedReceived;
            uint256 minimumReceived;
            if (betSize > 0) { // Don't need to determine swap tolerances if the bet is 0
                if (asset != wavaxAddress) {
                    require(investmentAssetsData[asset].purchasePath[0] == wavaxAddress, "Purchase paths must start with WAVAX.");
                    (betSize, expectedReceived) = swapRouter.findSwapAmountWithinTolerance(investmentAssetsData[asset].purchasePath,
                                                                                           betSize,
                                                                                           priceImpactTolerance);
                    minimumReceived = Library.subtractPercentage(expectedReceived, slippageTolerance);
                } else { // if I'm just sending WAVAX then I should receive the exact amount
                    minimumReceived = betSize;
                }
                betSize = Math.min(totalCashValue, betSize); // can't bet more than total cash on hand
            }
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
    function clearBuy(address asset, uint256 boughtAmount) internal whenNotPaused {
        require(boughtAmount <= investmentAssetsData[asset].buyAmount, "Cannot reduce buyAmount by more than it is.");
        require(investmentAssetsData[asset].reservedForBuy, "Attempting to clear buy with no buy reservation.");
        require(investmentAssetsData[asset].buyAmount > 0, "Attempting to clear buy with no buy amount.");
        investmentAssetsData[asset].buyAmount = 0;
        investmentAssetsData[asset].reservedForBuy = false;
        investmentAssetsData[asset].minimumReceived = 0;
    }

    // Called by the CashManager before making a purchase
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
    // TODO: This will need to be used when liquidations happen
    function drainExtraCash() external whenNotPaused { // anyone can call this
        // TODO: Prevent this from intefering with other calls by requiring a 1 hour wait after any call to
        // determineSell, determineBuy, or setInvestmentAsset
        if (numBuysAuthorized == 0) {
            require(wavax.allowance(address(this), address(cashManager)) == 0,
                    "Must start from 0 allowance to set allowance.");
            bool success = wavax.approve(address(cashManager), wavax.balanceOf(address(this)));
            require(success, "Approving the CashManager to take WAVAX failed.");
        }
    }

    // Uses cash on hand to make a purchase of a particular asset
    function processBuy(address asset) external whenNotPaused { // anyone can call this
        uint256 buyAmount = investmentAssetsData[asset].buyAmount;
        uint256 buyDeterminationTimestamp = investmentAssetsData[asset].buyDeterminationTimestamp;
        uint256 minimumReceived = investmentAssetsData[asset].minimumReceived;
        require(investmentAssetsData[asset].exists, "This asset isn't in the investment manager.");
        require(investmentAssetsData[asset].buyAmount > 0, "This asset doesn't have any authorized buy amount.");
        require(investmentAssetsData[asset].reservedForBuy, "asset must be reserved for this purchase.");
        require(minimumReceived > 0, "Must have a minimum received to enforce.");
        // TODO: This constraint could cause issues if the total cash value in WAVAX changed from the time the InvestmentManager was
        // called to the time this is called
        clearBuy(asset, buyAmount);
        cashManager.clearInvestmentReservation(buyAmount);
        if (block.timestamp < buyDeterminationTimestamp + (24 * 60 * 60)) { // actually process it only if it's not stale
            //require(wavax.balanceOf(address(this)) >= buyAmount, "Don't have sufficient WAVAX for this buyAmount.");
            // It's possible that liquidaitons to produce WAVAX dry powder didn't convert as much as desired due to
            // slippage constraints. In that situation, complete the buy as much as possible.
            uint256 wavaxOnHand = wavax.balanceOf(address(this));
            if (buyAmount > wavaxOnHand) { // Try to get WAVAX from the CashManager
                uint256 cashManagerWAVAXOnHand = wavax.balanceOf(address(cashManager));
                uint256 transferAmount = Math.min(buyAmount - wavaxOnHand, cashManagerWAVAXOnHand);
                uint256 approvedAmount = wavax.allowance(address(cashManager), address(this));
                require(approvedAmount >= transferAmount, "Not enough approved to transfer from CashManager.");
                bool success = wavax.transferFrom(address(cashManager),
                                                  address(this),
                                                  transferAmount);
                require(success);
            }
            // TODO: The  minimum here should actually be above 0, it should be some multiple of transation cost
            // It doesn't make sense to do a swap when the amount being swapped is less than gas cost
            wavaxOnHand = wavax.balanceOf(address(this));
            if (buyAmount > wavaxOnHand) {
                uint256 percentageOfTargetWAVAX = Library.valueIsWhatPercentOf(wavaxOnHand, buyAmount);
                buyAmount = Math.min(buyAmount, wavaxOnHand);
                minimumReceived = Library.percentageOf(minimumReceived, percentageOfTargetWAVAX);
            }
            if ((buyAmount > 0) && (asset != address(wavax))) { // Do nothing if there is no WAVAX on hand for this investment
                // swap and send to the InvestmentManager
                bool success = wavax.approve(address(joeRouter), buyAmount);
                require(success, "token approval failed.");

                // Do the swap
                uint256[] memory amounts = joeRouter.swapExactTokensForTokens(buyAmount,
                                                                              minimumReceived, // Define a minimum received
                                                                              investmentAssetsData[asset].purchasePath,
                                                                              address(this),
                                                                              block.timestamp);
                require(amounts[0] == buyAmount, "Didn't sell the amount of tokens inserted.");
                require(amounts[amounts.length - 1] >= minimumReceived, "Didn't get out as much as expected.");
            }
        }
    }
}
