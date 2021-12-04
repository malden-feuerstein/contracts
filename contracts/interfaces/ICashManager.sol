//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "contracts/interfaces/IRedeemable.sol";

interface ICashManager is IRedeemable {
    function cashAssetsAllocations(address) external view returns (uint256);
    function cashAssetsPrices(address) external view returns(uint256);
    function totalUSDValue() external view returns (uint256);
    function clearInvestmentReservation(uint256 buyAmount) external; // Only the InvestmentManager can call this
}
