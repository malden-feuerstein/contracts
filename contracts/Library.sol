//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "hardhat/console.sol"; // TODO: Remove this for production
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeFactory.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoePair.sol";

library Library {
    struct PriceQuote {
        uint256 price;
        uint8 decimals;
        address token0;
        address token1;
    }

    // Use this to get the decimals right any time you're multiplying an amount of a token by the price of token
    // This is typically for changing an amount of a token into its USD value
    // usdAmount = tokenAmount * price / decimals;
    function priceMulAmount(uint256 tokenAmount, uint8 decimals, uint256 price) internal pure returns (uint256) {
        return (tokenAmount * price) / (10 ** decimals);
    }

    // This is usually for converting a USD amount, along with a price in USD, into an amount of a token
    // Take the USD amount, the price in USD, and the number of decimals in the destination token
    // tokenAmount = (usdAmount * decimals) / price;
    function amountDivPrice(uint256 amount, uint256 price, uint8 decimals) internal pure returns (uint256) {
        require(price > 0, "Cannot divide by 0 price.");
        return (amount * (10 ** decimals)) / price;
    }

    // Given two values, return what percentage of value2 value1 is
    // Be aware that this loses the fractional part of the division, so there may be rounding errors
    // Returns micro pecentage (percentage with 6 decimal places)
    function valueIsWhatPercentOf(uint256 value1, uint256 value2) internal pure returns (uint256) {
        require(value2 > 0, "Can't compare to 0 value2.");
        return (value1 * 100 * (10 ** 6)) / value2;
    }

    // value * percentage. Be aware that this loses the fractioanl part of the division, so there may be rounding errors
    // Expects percentage to be in micro percentages == perentage * (10**6)
    function percentageOf(uint256 value, uint256 percentage) internal pure returns (uint256) {
        return (value * percentage) / (100 * (10 ** 6));
    }

    // Subtract a percentage of the given value from the given value
    // Expects percentage to be given in micro percentage points
    function subtractPercentage(uint256 value, uint256 percentage) internal pure returns (uint256) {
        require(percentage > 0, "Cannot subtract 0 percentage.");
        return value - ((value * percentage) / (100 * (10 ** 6)));
    }

    // Add a percentage of the given value to the given value
    // Expects percentage to be in micro percentage points (that is, percentage with 6 decimal places)
    function addPercentage(uint256 value, uint256 percentage) internal pure returns (uint256) {
        require(percentage > 0, "Cannot add 0 percentage.");
        return value + ((value * percentage) / (100 * (10 ** 6)));
    }

    // Returns the kelly fraction in micro precentage points
    // Takes the confidence in micro percentage points
    // https://en.wikipedia.org/wiki/Kelly_criterion#Investment_formula
    function kellyFraction(uint256 confidence, uint256 lossPercent, uint256 gainPercent) internal pure returns (uint256) {
        require(confidence <= (100 * (10 ** 6))); // can not be more than 100% confident
        require(confidence > 0, "Cannot have a confidence of 0.");
        uint256 positive = ((confidence * (10 ** 6)) / lossPercent);
        uint256 negative = (((100 * (10 ** 6)) - confidence) * (10 ** 6)) / gainPercent;
        if (negative > positive) { // in this situation the kelly criterion is saying to bet nothing, it's not worth it
            return 0;
        } else {
            return (positive - negative) * 100;
        }
    }
}
