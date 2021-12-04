//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

interface IInvestmentManager {
    struct InvestmentAsset {
      address assetAddress;
      uint256 intrinsicValue; // intrinsive value estimate in USDT
      address[] liquidatePath;
      address[] purchasePath;
      uint256[] prices;
      uint256[] priceTimestamps;
      uint256 confidence; // probability of success in micro percentage points
      uint256 sellAmount;
      uint256 buyAmount; // Amount of WAVAX to swap for a purchase, slippage already taken into account
      uint256 minimumReceived;
      uint256 buyDeterminationTimestamp; // timestamp of when the buy amount was determined
      bool exists;
      bool reservedForBuy;
    }

    function investmentAssetsData(address) external view returns(address assetAddress,
                                                                 uint256 intrinsicValue,
                                                                 uint256 confidence,
                                                                 uint256 sellAmount,
                                                                 uint256 buyAmount,
                                                                 uint256 minimumReceived,
                                                                 uint256 buyDeterminationTimestamp,
                                                                 bool exists,
                                                                 bool reservedForBuy);

    function reserveForCashManagerPurchase(address asset, uint256 buyAmount) external;

    function getBuyPath(address asset) view external returns (address[] memory);

    function totalValueInWAVAX() view external returns (uint256);
}
