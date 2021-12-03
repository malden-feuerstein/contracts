//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

interface ICashManager {
    function cashAssets(uint256 index) external view returns(address);
    function numberOfCashAssets() external view returns(uint length);
    function cashAssetsAllocations(address) external view returns (uint256);
    function cashAssetsPrices(address) external view returns(uint256);
    function totalUSDValue() external view returns (uint256);
}
