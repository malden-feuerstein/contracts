import {
  Contract, 
  ContractFactory,
  BigNumber
} from "ethers"
import { ethers, upgrades } from "hardhat"
import { expect } from "chai";
import { addresses, liquidatePaths, purchasePaths } from "./addresses";

// This should be set to the value in Library.sol
const PERCENTAGE_DECIMALS = 6;

function multiplyByDecimals(array, numDecimals) {
    return array.map(x => BigNumber.from(x).pow(numDecimals));
}

async function processAllLiquidations(cashManager, user) {
    const numLiquidations = await cashManager.connect(user).numLiquidationsToProcess();
    for (let i = 0; i < numLiquidations; i++) {
        await cashManager.connect(user).processLiquidation();
    }
}

async function processAllPurchases(cashManager, user) {
    const numPurchases = await cashManager.connect(user).numPurhcasesToProcess();
    for (let i = 0; i < numPurchases; i++) {
        await cashManager.connect(user).processPurchase();
    }
}

function testBigNumberIsWithinInclusiveBounds(value, lowerBound, upperBound) {
    const isLessThan = value.lte(upperBound);
    const isGreaterThan = value.gte(lowerBound);
    expect(isLessThan).to.be.equal(true, `${value.toString()} not less than ${upperBound.toString()}`);
    expect(isGreaterThan).to.be.equal(true, `${value.toString()} not greater than ${lowerBound.toString()}`);
}

async function balanceCashHoldingsTest(contracts, user, expectedAssets, expectedPercentages) {
    let cashManager = contracts.cashManager;
    let valueHelpers = contracts.valueHelpers;
    await cashManager.connect(user).updateLiquidationsAndPurchases();
    await processAllLiquidations(cashManager, user);
    await processAllPurchases(cashManager, user);
    const one_percent = BigNumber.from("1").mul(10 ** PERCENTAGE_DECIMALS); // 6 decimal places to a percentage
    for (let i = 0; i < expectedAssets.length; i++) {
        const asset = expectedAssets[i];
        const percentage = expectedPercentages[i];
        const lower = ethers.BigNumber.from(expectedPercentages[i]).sub(one_percent);
        const upper = ethers.BigNumber.from(expectedPercentages[i]).add(one_percent);
        const actualPercentage = await valueHelpers.connect(user).assetPercentageOfCashManager(asset);
        testBigNumberIsWithinInclusiveBounds(actualPercentage, lower, upper);
    }
}

let epsilonEther = ethers.utils.parseUnits("0.0007", "ether"); // A three dollar discrepancy at $4000/eth

export async function testTokenAmountWithinBounds(tokenAddress, user, balanceHolder, expectedAmount) {
    const tokenContract = await ethers.getContractAt("IERC20", tokenAddress);
    const tokenAmount = await tokenContract.connect(user).balanceOf(balanceHolder);
    const upperBound = ethers.utils.parseUnits(expectedAmount, "ether").add(epsilonEther);
    const lowerBound = ethers.utils.parseUnits(expectedAmount, "ether").sub(epsilonEther);
    testBigNumberIsWithinInclusiveBounds(tokenAmount, lowerBound, upperBound);
}

// This is a convenience function for tests to set up cash manager allocations
// These are also the cash manager asset allocations that are planned to be used in production
export async function setCashManagerAllocations(cashManager, owner, user, investmentAmount) :
    Promise<{assets: string[], allocations: number[]}> {
    var assets = [addresses.wavax,
                  addresses.wbtc,
                  addresses.weth,
                  addresses.usdt,
                  addresses.usdc,
                  addresses.dai];
    var allocations = [20, 15, 15, 20, 15, 15].map(x => x * (10 ** PERCENTAGE_DECIMALS));
    var liquidationPaths = [liquidatePaths.wavax,
                            liquidatePaths.wbtc,
                            liquidatePaths.weth,
                            liquidatePaths.usdt,
                            liquidatePaths.usdc,
                            liquidatePaths.dai];
    var localPurchasePaths = [purchasePaths.wavax,
                              purchasePaths.wbtc,
                              purchasePaths.weth,
                              purchasePaths.usdt,
                              purchasePaths.usdc,
                              purchasePaths.dai];
    await cashManager.connect(owner).setCashAllocations(assets,
                                                        allocations,
                                                        liquidationPaths,
                                                        localPurchasePaths);
    expect(await cashManager.connect(user).numAssets()).to.equal(6);
    expect(await cashManager.connect(user).numAssets()).to.not.equal(7);
    expect(await cashManager.connect(user).numAssets()).to.not.equal(5);
    const wavax = await ethers.getContractAt("IWAVAX", addresses.wavax);
    await expect(await wavax.connect(user).balanceOf(cashManager.address)).to.equal(investmentAmount);
    return {assets, allocations}
}

// Once the allocations have been set on the CashManager, do all of the necessary purchases and liquidations to
// bring the holdings into alignment with the target allocations
export async function makeCashManagerAllocations(contracts, assets, allocations, user) {
    let cashManager = contracts.cashManager;
    let valueHelpers = contracts.valueHelpers;
    const wavax = await ethers.getContractAt("IWAVAX", addresses.wavax);
    await cashManager.connect(user).updateCashPrices();
    await cashManager.connect(user).updateLiquidationsAndPurchases();
    let numLiquidationsToProcess = await cashManager.connect(user).numLiquidationsToProcess();
    if (numLiquidationsToProcess > 0) {
        await processAllLiquidations(cashManager, user);
    } else {
        await expect(cashManager.connect(user).processLiquidation()).to.be.revertedWith(
            "There are no liquidations queued from a call to updateLiquidationsAndPurchases().");
    }
    await processAllPurchases(cashManager, user);
    const one_percent = BigNumber.from("1").mul(10 ** PERCENTAGE_DECIMALS);
    for (let i = 0; i < assets.length; i++) {
        const asset = assets[i];
        const percentage = allocations[i];
        const lower = ethers.BigNumber.from(allocations[i]).sub(one_percent);
        const upper = ethers.BigNumber.from(allocations[i]).add(one_percent);
        const actualPercentage = await valueHelpers.connect(user).assetPercentageOfCashManager(asset);
        if (actualPercentage > 0) {
            testBigNumberIsWithinInclusiveBounds(actualPercentage, lower, upper);
        } else {
            expect(await valueHelpers.connect(user).cashManagerTotalValueInWAVAX()).to.be.equal(0);
        }
    }
}

export { processAllLiquidations, processAllPurchases, balanceCashHoldingsTest, testBigNumberIsWithinInclusiveBounds };
