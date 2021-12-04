//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

interface IValueHelpers {
    function cashManagerTotalValueInWAVAX() external view returns (uint256);
    function assetPercentageOfCashManager(address asset) external view returns (uint256 value);
}
