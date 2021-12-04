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
import "contracts/interfaces/IWAVAX.sol";
import "contracts/interfaces/ISwapRouter.sol";
import "contracts/interfaces/IMaldenFeuersteinERC20.sol";
import "contracts/interfaces/IInvestmentManager.sol";
import "contracts/interfaces/IValueHelpers.sol";
import "contracts/Library.sol";
import "contracts/interfaces/IRedeemable.sol";

// Functions for approving liquidations and performing those liquidations
abstract contract Redeemable is IRedeemable {
    event Liquidated(address); // emitted when an asset is liquidated because it's no longer a cash holding

    // constants
    enum ManagerChoice { CashManager, InvestmentManager }
    ManagerChoice managerChoice;
    uint256 internal priceImpactTolerance; // price impact micro percentage
    uint256 internal slippageTolerance; // swap slippage tolerance in micro percentage

    // contracts
    address internal wavaxAddress;
    IWAVAX internal wavax;
    ISwapRouter internal swapRouter;
    IMaldenFeuersteinERC20 internal coin;
    IJoeRouter02 internal joeRouter;

    // storage
    // An array of all assets
    // Can have at most uint16 max value length = 65535
    address[] public assets;
    mapping(address => uint256) internal assetLiquidationAmounts; // Amount of each token to sell, denominated in token
    address[] internal liquidationsToPerform;
    mapping(address => address[]) internal liquidatePaths;

    // Convenience function
    function numAssets() external view returns(uint length) {
        return assets.length;
    }

    function numLiquidationsToProcess() external view returns (uint256) {
        return liquidationsToPerform.length;
    }

    // Execute a swap to complete a previously stored liquidation
    // This needs to be callable even when paused so that users can redeem their tokens
    function processLiquidation() external { // Anyone can call this
        require(liquidationsToPerform.length > 0,
                "There are no liquidations queued from a call to updateLiquidationsAndPurchases().");
        address asset = liquidationsToPerform[liquidationsToPerform.length - 1];
        require(asset != address(wavax),
                "WAVAX is the asset of purchasing power, it is liquidated merely by purchasing other assets.");
        require(liquidatePaths[asset].length > 0, "Must have a valid liquidation path to be able to perform a swap.");

        // Set state before external calls
        emit Liquidated(asset);
        liquidationsToPerform.pop();

        address[] memory path = liquidatePaths[asset];
        uint256 desiredAmountToSwap = assetLiquidationAmounts[asset];
        require(desiredAmountToSwap > 0, "Got a 0 desiredAmountToSwap.");
        uint256 amountToSwap;
        uint256 expectedReceived;
        (amountToSwap, expectedReceived) = swapRouter.findSwapAmountWithinTolerance(path,
                                                                                    desiredAmountToSwap,
                                                                                    priceImpactTolerance);
        IERC20 fromToken = IERC20(path[0]);
        require(fromToken.balanceOf(address(this)) >= amountToSwap, "Cannot approve swapping more than on hand.");
        bool success = fromToken.approve(address(joeRouter), amountToSwap);
        require(success, "token approval failed.");

        // Do the swap
        uint256 minimumReceived = Library.subtractPercentage(expectedReceived, slippageTolerance);
        uint256[] memory amounts = joeRouter.swapExactTokensForTokens(amountToSwap,
                                                                      minimumReceived,
                                                                      path,
                                                                      address(this),
                                                                      block.timestamp);
        require(amounts[0] == amountToSwap, "Didn't sell the amount of tokens inserted.");
        require(amounts[amounts.length - 1] >= minimumReceived, "Didn't get out as much as expected.");
    }
    
    // Take the amount of WAVAX needed and the current total WAVAX on hand
    // Authorize liquidations to get the total WAVAX on hand up amountNeeded
    // This must be callable when paused so that users can redeem their tokens
    // Don't call this if there is already more WAVAX on hand than amountNeeded, it will cause an arithmetic error
    function prepareDryPowder(uint256 amountNeeded, uint256 wavaxOnHand) internal { // only be called by this contract
        // iterate the cash assets, authorizing liquidations until we have enough WAVAX
        // TODO: This iterates through the assets randomly,
        // but I might actually want to do it in order of biggest to smallest?
        for (uint256 i = 0; i < assets.length; i++) {
            address liquidateAsset = assets[i];
            if (liquidateAsset == wavaxAddress) { // WAVAX was already included above and doesn't need to be swapped
                continue;
            }
            IERC20 liquidateToken = IERC20(liquidateAsset);
            uint256 liquidateTokenOnHand = liquidateToken.balanceOf(address(this));
            // TODO: This doesn't support multi-hop paths
            Library.PriceQuote memory priceQuote = swapRouter.getPriceQuote(liquidateAsset, wavaxAddress);
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
                if (amountToLiquidate > 0) {
                    liquidationsToPerform.push(liquidateAsset);
                    wavaxOnHand += differenceNeeded;
                }
                break; // This one is enough, don't need to continue iterating
            } else { // it's not enough, so add all of it and go to the next
                assetLiquidationAmounts[liquidateAsset] = liquidateTokenOnHand;
                if (liquidateTokenOnHand > 0) {
                    liquidationsToPerform.push(liquidateAsset);
                    wavaxOnHand += liquidateTokenValueInWAVAX;
                }
            }
        }
    }

    // Call this before processing a redemption to authorize any liquidations necessary to get enough WAVAX out
    // This needs to be callable when paused so that users can redeem their tokens
    function prepareDryPowderForRedemption() external {
        uint256 maldenCoinAmount;
        uint256 wavaxAmount;
        // FIXME: For this to work with the InvestmentManager it needs to use the second value rather than the first
        if (managerChoice == ManagerChoice.CashManager) {
            (maldenCoinAmount, wavaxAmount, ) = coin.getAuthorizedRedemptionAmounts(msg.sender);
        } else {
            uint256 cashManagerWAVAXAmount;
            (maldenCoinAmount, cashManagerWAVAXAmount, wavaxAmount) = coin.getAuthorizedRedemptionAmounts(msg.sender);
            require(cashManagerWAVAXAmount > 0);
        }
        require(maldenCoinAmount > 0, "Not authorized to liquidate for redemption.");
        require(wavaxAmount > 0, "Not authorized to liquidate for redemption.");
        uint256 wavaxOnHand = wavax.balanceOf(address(this));
        if (wavaxOnHand < wavaxAmount) { // Prepare additional dry powder only if needed
            prepareDryPowder(wavaxAmount, wavaxOnHand);
        }
        // Authorize the coin to take the WAVAX from this contract
        // let the Coin take the WAVAX to give to the user
        bool success = wavax.approve(address(coin), wavaxAmount);
        require(success, "wavax approval to the MALD coin failed.");
    }

}
