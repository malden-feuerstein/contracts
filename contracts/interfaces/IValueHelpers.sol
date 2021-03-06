//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

interface IValueHelpers {
    function cashManagerTotalValueInWAVAX() external view returns (uint256);
    function investmentManagerTotalValueInWAVAX() view external returns (uint256);
    function assetPercentageOfCashManager(address asset) external view returns (uint256 value);
    function investmentManagerAssetValueInWAVAX(address asset) view external returns (uint256);
}
