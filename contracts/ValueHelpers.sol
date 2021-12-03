//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// local
import "contracts/IERC20.sol";
import "contracts/IValueHelpers.sol";
import "contracts/Library.sol";
import "contracts/ICashManager.sol";
import "contracts/IWAVAX.sol";
import "contracts/ISwapRouter.sol";

contract ValueHelpers is OwnableUpgradeable, UUPSUpgradeable, IValueHelpers {

    address wavaxAddress;
    IWAVAX wavax;
    ICashManager cashManager;
    ISwapRouter swapRouter;

    function initialize() external virtual initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setAddresses(address localWAVAXAddress, address cashManagerAddress, address swapRouterAddress) external onlyOwner {
        wavaxAddress = localWAVAXAddress;
        wavax = IWAVAX(localWAVAXAddress);
        cashManager = ICashManager(cashManagerAddress);
        swapRouter = ISwapRouter(swapRouterAddress);
    }

    // Return the total value of everything in the cash manager denominated in WAVAX
    function cashManagerTotalValueInWAVAX() external view returns (uint256) { // anyone can call this
        uint256 totalValue = 0;
        for (uint16 i = 0; i < cashManager.numberOfCashAssets(); i++) {
            address asset = cashManager.cashAssets(i);
            if (asset == wavaxAddress) { // don't try to swap WAVAX to WAVAX
                uint256 wavaxBalance = wavax.balanceOf(address(cashManager));
                totalValue += wavaxBalance;
            } else {
                IERC20 token = IERC20(asset);
                uint256 tokenBalance = token.balanceOf(address(cashManager));
                // TODO: This assumes that asset -> wavax exists, but need to use the liquidatePath
                Library.PriceQuote memory priceInWAVAX = swapRouter.getPriceQuote(asset, wavaxAddress);
                uint256 valueInWAVAX = Library.priceMulAmount(tokenBalance, token.decimals(), priceInWAVAX.price);
                totalValue += valueInWAVAX;
            }
        }
        // Any WAVAX on hand needs to be counted toward the total
        if (cashManager.cashAssetsAllocations(wavaxAddress) == 0) {
            uint256 wavaxBalance = wavax.balanceOf(address(cashManager));
            totalValue += wavaxBalance;
        }
        return totalValue;
    }

    // A convenience function to return what % of total USD portfolio value this asset is, according to the contract
    // Note that the prices are updates potentially every minute by calls to updateCashPrices, whereas
    // the totalUSDValue is updated at most once per day by calls to
    function assetPercentageOfCashManager(address asset) external view returns (uint256 value) {
        uint256 priceInUSD = cashManager.cashAssetsPrices(asset);
        require(priceInUSD > 0, "This asset isn't stored in cash prices.");
        IERC20 token = IERC20(asset);
        uint256 assetValueInUSD = Library.priceMulAmount(token.balanceOf(address(cashManager)), token.decimals(), priceInUSD);
        return Library.valueIsWhatPercentOf(assetValueInUSD, cashManager.totalUSDValue());
    }
}
