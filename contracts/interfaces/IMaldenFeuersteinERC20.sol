//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface IMaldenFeuersteinERC20 {
    function getAuthorizedRedemptionAmounts(address user) external view returns (uint256, uint256);
}
