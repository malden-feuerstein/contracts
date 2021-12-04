//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

interface IRedeemable {
    function assets(uint256 index) external view returns(address);
    function numAssets() external view returns(uint length);
}
