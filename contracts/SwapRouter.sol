//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
//import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeRouter02.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeFactory.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoePair.sol";
import "hardhat/console.sol"; // TODO: Remove this for production

// local
import "contracts/IWAVAX.sol";
import "contracts/IERC20.sol";
import "contracts/Library.sol";

// Everything in this contract should be view or internal

contract SwapRouter is OwnableUpgradeable, UUPSUpgradeable {
    struct PriceQuote {
        uint256 price;
        uint8 decimals;
        address token0;
        address token1;
    }
    IJoeFactory private joeFactory;
    IJoeRouter02 public joeRouter; // TODO: this should probably be set on construction

    function initialize() external virtual initializer {
        __Ownable_init();
        // FIXME: Make these upgradable
        joeFactory = IJoeFactory(0x9Ad6C38BE94206cA50bb0d90783181662f0Cfa10);
        joeRouter = IJoeRouter02(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // Get the reserve amounts in the TraderJoe trading pair
    function getReserveAmounts(IJoeFactory localJoeFactory,
                               address asset0,
                               address asset1) public view returns (uint256, uint256) {
        address pairAddress = localJoeFactory.getPair(asset0, asset1);
        require(pairAddress != address(0), "Requested a pair that does not exist.");
        IJoePair pair = IJoePair(pairAddress);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        // Important note: IJoePair has variables token0 and token1, and it's random as to which order they will be in
        // They may be in flipped order of my asset0 and asset1 even though I passed them in order
        // When this happens, flip around the reserves so that they correspond to the inputs
        if (asset0 != pair.token0()) {
            uint112 holdValue = reserve0;
            reserve0 = reserve1;
            reserve1 = holdValue;
        }
        return (reserve0, reserve1);
    }

    // This returns a price quote denominated in asset1, so it will have the decimals of asset1
    function getPriceQuote(address asset0, address asset1) external view returns (PriceQuote memory) {
        (uint256 reserve0, uint256 reserve1) = getReserveAmounts(joeFactory, asset0, asset1);
        IERC20 token0 = IERC20(asset0);
        IERC20 token1 = IERC20(asset1);
        uint256 price = (reserve1 * (10 ** token0.decimals())) / reserve0;
        return PriceQuote(price, token1.decimals(), address(token0), asset1);
    }

    // Check if TraderJoe has sufficient liquidity
    // asset1 is the starting token and asset2 is the destination token
    // Returns the price impact in micro precent. To turn it into a percentage, divide by 10**6
    function priceImpact(address asset0,
                         address asset1,
                         uint256 asset0Amount) public view returns (uint256, uint256) {
        IERC20 token1 = IERC20(asset1);
        (uint256 reserve0, uint256 reserve1) = getReserveAmounts(joeFactory, asset0, asset1);
        uint256 price = (reserve0 * (10 ** token1.decimals())) / reserve1;
        uint256 constantProduct = reserve0 * reserve1;
        uint256 newReserve0 = reserve0 + asset0Amount;
        uint256 newReserve1 = constantProduct / newReserve0;
        assert(reserve1 > newReserve1);
        uint256 receivedAsset1 = reserve1 - newReserve1;
        uint256 newPrice = (asset0Amount * (10 ** token1.decimals())) / receivedAsset1;
        uint256 thePriceImpact = ((newPrice - price) * (10 ** 6) * 100) / price;
        return (thePriceImpact, receivedAsset1);
    }

    // Apply priceImpact() to a path of arbitrary length
    // Returns the total price impact percentage in micro percentage points (percentage points with 6 decimals)
    // Returns the expected amount of the final token in the path
    function priceImpactOfPath(address[] calldata path, uint256 amountToSwap) public view returns (uint256, uint256) {
        uint256 resultPriceImpact = 0;
        uint256 pathPriceImpact;
        uint256 receivedAsset1;
        for (uint8 i = 0; i < path.length - 1; i++) { // uint8 because will never have an AMM path of length greater than 256
            (pathPriceImpact, receivedAsset1) = priceImpact(path[i], path[i + 1], amountToSwap);
            amountToSwap = receivedAsset1; // The amount to swap on the next leg of the path is the amount received from this leg
            // https://towardsdatascience.com/
            // most-people-screw-up-multiple-percent-changes-heres-how-to-do-get-them-right-b86bd6ef4b72
            resultPriceImpact = (resultPriceImpact + pathPriceImpact) +
                                (resultPriceImpact * pathPriceImpact); // accumulate percentages
        }
        return (resultPriceImpact, amountToSwap);
    }

    // Determine what the price impact will be and halve the amount to swap until it's within the price impact tolerance
    function findSwapAmountWithinTolerance(address[] calldata path,
                                           uint256 amountToSwap,
                                           uint256 priceImpactTolerance) external view returns (uint256, uint256) {
        uint256 priceImpactHere;
        uint256 expectedAmount;
        (priceImpactHere, expectedAmount) = priceImpactOfPath(path, amountToSwap);
        while (priceImpactHere > priceImpactTolerance) { // Swap less than desired if it would affect price too much
            amountToSwap /= 2; // Try cutting the amount in half
            console.log("WARNING: Halving swap amount to fit within priceImpactTolerance");
            (priceImpactHere, expectedAmount) = priceImpactOfPath(path, amountToSwap);
        }
        return (amountToSwap, expectedAmount);
    }
}
