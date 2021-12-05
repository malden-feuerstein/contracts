//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// local
import "contracts/interfaces/IERC20.sol";
import "contracts/interfaces/IValueHelpers.sol";
import "contracts/interfaces/ICashManager.sol";
import "contracts/interfaces/IWAVAX.sol";
import "contracts/interfaces/ISwapRouter.sol";
import "contracts/interfaces/IInvestmentManager.sol";
import "contracts/Library.sol";

contract ValueHelpers is OwnableUpgradeable, UUPSUpgradeable, IValueHelpers {

    address wavaxAddress;
    IWAVAX wavax;
    ICashManager cashManager;
    ISwapRouter swapRouter;
    IInvestmentManager investmentManager;

    function initialize() external virtual initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setAddresses(address localWAVAXAddress,
                          address cashManagerAddress,
                          address swapRouterAddress,
                          address investmentManagerAddress) external onlyOwner {
        require(localWAVAXAddress != address(0), "Cannot set WAVAX address to 0");
        wavaxAddress = localWAVAXAddress;
        wavax = IWAVAX(localWAVAXAddress);
        cashManager = ICashManager(cashManagerAddress);
        swapRouter = ISwapRouter(swapRouterAddress);
        investmentManager = IInvestmentManager(investmentManagerAddress);
    }

    // Return the total value of everything in the cash manager denominated in WAVAX
    function cashManagerTotalValueInWAVAX() external view returns (uint256) { // anyone can call this
        uint256 totalValue = 0;
        for (uint16 i = 0; i < cashManager.numAssets(); i++) {
            address asset = cashManager.assets(i);
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

    function investmentManagerAssetValueInWAVAX(address asset) view public returns (uint256) {
        IERC20 token = IERC20(asset);
        uint256 tokenBalance = token.balanceOf(address(investmentManager));
        if (asset == wavaxAddress) {
            return tokenBalance;
        } else {
            // TODO: This assumes that asset -> wavax exists, but need to use the liquidatePath
            Library.PriceQuote memory priceInWAVAX = swapRouter.getPriceQuote(asset, wavaxAddress);
            return Library.priceMulAmount(tokenBalance, token.decimals(), priceInWAVAX.price);
        }
    }

    // Return the total value of everything in the investment manager denominated in WAVAX
    // TODO: This is a near duplicate of the same function in the CashManager. Ideally I wouldn't have this code duplication,
    // but I'm unable to solve it because OpenZeppelin's upgradeability doesn't allow Library functions that modify state, nor
    // the use of delegatecall
    function investmentManagerTotalValueInWAVAX() view external returns (uint256) { // anyone can call this
        uint256 totalValue = 0;
        for (uint16 i = 0; i < investmentManager.numAssets(); i++) {
            address asset = investmentManager.assets(i);
            if (asset == wavaxAddress) { // don't try to swap WAVAX to WAVAX
                uint256 wavaxBalance = wavax.balanceOf(address(investmentManager));
                totalValue += wavaxBalance;
            } else {
                totalValue += investmentManagerAssetValueInWAVAX(asset);
            }
        }
        // Any WAVAX on hand that isn't considered an investment needs to be counted
        bool exists;
        (, , , , , , , exists, ) = investmentManager.investmentAssetsData(address(wavax));
        if (!exists) {
            uint256 wavaxBalance = wavax.balanceOf(address(investmentManager));
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
        uint256 cashManagerValue = cashManager.totalUSDValue();
        if (cashManagerValue == 0) {
            return 0;
        } else {
            return Library.valueIsWhatPercentOf(assetValueInUSD, cashManager.totalUSDValue());
        }
    }
}
