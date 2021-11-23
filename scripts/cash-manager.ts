import { 
  Contract, 
  ContractFactory,
  BigNumber
} from "ethers"
import { ethers, upgrades } from "hardhat"
import { expect } from "chai";

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

async function balanceCashHoldingsTest(cashManager, user, expectedAssets, expectedPercentages) {
    await cashManager.connect(user).updateLiquidationsAndPurchases();
    await processAllLiquidations(cashManager, user);
    await processAllPurchases(cashManager, user);
    const one_percent = BigNumber.from("1000000");
    for (let i = 0; i < expectedAssets.length; i++) {
        const asset = expectedAssets[i];
        const percentage = expectedPercentages[i];
        const lower = ethers.BigNumber.from(expectedPercentages[i]).sub(one_percent);
        const upper = ethers.BigNumber.from(expectedPercentages[i]).add(one_percent);
        const actualPercentage = await cashManager.connect(user).assetPercentageOfPortfolio(asset);
        testBigNumberIsWithinInclusiveBounds(actualPercentage, lower, upper);
    }
}

export { processAllLiquidations, processAllPurchases, balanceCashHoldingsTest, testBigNumberIsWithinInclusiveBounds };
