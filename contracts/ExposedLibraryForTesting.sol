//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

// local
import "contracts/Library.sol"; // local file

library ExposedLibraryForTesting {
    // Use this to get the decimals right any time you're multiplying an amount of a token by the price of token
    // This is typically for changing an amount of a token into its USD value
    // usdAmount = tokenAmount * price / decimals;
    function priceMulAmount(uint256 tokenAmount, uint8 decimals, uint256 price) external pure returns (uint256) {
        return Library.priceMulAmount(tokenAmount, decimals, price);
    }

    // This is usually for converting a USD amount, along with a price in USD, into an amount of a token
    // Take the USD amount, the price in USD, and the number of decimals in the destination token
    // tokenAmount = (usdAmount * decimals) / price;
    function amountDivPrice(uint256 amount, uint256 price, uint8 decimals) external pure returns (uint256) {
        return Library.amountDivPrice(amount, price, decimals);
    }

    // Given two values, return what percentage of value2 value1 is
    // Be aware that this loses the fractional part of the division, so there may be rounding errors
    function valueIsWhatPercentOf(uint256 value1, uint256 value2) external pure returns (uint256) {
        return Library.valueIsWhatPercentOf(value1, value2);
    }

    // value * percentage. Be aware that this loses the fractioanl part of the division, so there may be rounding errors
    function percentageOf(uint256 value, uint256 percentage) external pure returns (uint256) {
        return Library.percentageOf(value, percentage);
    }

    // Subtract a percentage of the given value from the given value
    function subtractPercentage(uint256 value, uint256 percentage) external pure returns (uint256) {
        return Library.subtractPercentage(value, percentage);
    }

    // Add a percentage of the given value to the given value
    function addPercentage(uint256 value, uint256 percentage) external pure returns (uint256) {
        return Library.addPercentage(value, percentage);
    }

    function kellyFraction(uint256 confidence, uint256 lossPercent, uint256 gainPercent) external pure returns (uint256) {
        return Library.kellyFraction(confidence, lossPercent, gainPercent);
    }

    function PERCENTAGE_DECIMALS() external pure returns (uint8) {
        return Library.PERCENTAGE_DECIMALS;
    }
}
