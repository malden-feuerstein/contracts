//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeFactory.sol";
import "contracts/Library.sol";

interface ISwapRouter {
    function getReserveAmounts(IJoeFactory localJoeFactory,
                               address asset0,
                               address asset1) external view returns (uint256, uint256);
    function getPriceQuote(address asset0, address asset1) external view returns (Library.PriceQuote memory);
    function priceImpact(address asset0,
                         address asset1,
                         uint256 asset0Amount) external view returns (uint256, uint256);
    function priceImpactOfPath(address[] calldata path, uint256 amountToSwap) external view returns (uint256, uint256);
    function findSwapAmountWithinTolerance(address[] calldata path,
                                           uint256 amountToSwap,
                                           uint256 priceImpactTolerance) external view returns (uint256, uint256);
}
