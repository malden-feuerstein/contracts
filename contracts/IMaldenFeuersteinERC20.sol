//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "contracts/IERC20.sol";

interface IMaldenFeuersteinERC20 is IERC20 {
    function getAuthorizedRedemptionAmounts(address user) external view returns (uint256, uint256);
}
