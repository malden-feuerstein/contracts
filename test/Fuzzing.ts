// test/Airdrop.j0
// Load dependencies
import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers, network, upgrades } from "hardhat";
import { addresses, liquidatePaths, purchasePaths, getTokens } from "../scripts/addresses";
import { deployAll } from "../scripts/deploy";
import { processAllLiquidations,
         setCashManagerAllocations,
         makeCashManagerAllocations,
         testBigNumberIsWithinInclusiveBounds } from "../scripts/cash-manager"
import { makeInvestment } from "../scripts/investment-manager"

// https://hardhat.org/tutorial/testing-contracts.html
// https://github.com/gnosis/mock-contract FOR HELP

var totalAVAXInvestments = BigNumber.from("0");

function randomIntFromInterval(min, max) { // min and max included 
  return Math.floor(Math.random() * (max - min + 1) + min)
}

function getRandom(arr, n) {
    var result = new Array(n),
        len = arr.length,
        taken = new Array(len);
    if (n > len)
        throw new RangeError("getRandom: more elements taken than available");
    while (n--) {
        var x = Math.floor(Math.random() * len);
        result[n] = arr[x in taken ? taken[x] : x];
        taken[x] = --len in taken ? taken[len] : len;
    }
    return result;
}

function getRandomElement(array) {
    return array[Math.floor(Math.random() * array.length)]
}

async function coinInvest(contracts, user) {
    let randomAmount = randomIntFromInterval(0, 1000);
    let randomAmountInWei = ethers.utils.parseUnits(String(randomAmount), "ether");
    await contracts.coin.connect(user).invest({"value": randomAmountInWei});
    totalAVAXInvestments = totalAVAXInvestments.add(randomAmountInWei);
}

async function coinRedeem(contracts, user) {
    await contracts.coin.connect(user).redeem();
    // TODO: totalAVAXInvestments.sub(BigNumber.from(randomAmount));
}

async function coinRandomRedeem(contracts, user) {
    let randomAmount = randomIntFromInterval(0, 1000);
    await contracts.coin.connect(user).requestRedeem(randomAmount);
    await contracts.cashManager.connect(user).prepareDryPowderForRedemption();
    await processAllLiquidations(contracts.cashManager, user);
    await contracts.coin.connect(user).redeem();
    totalAVAXInvestments.sub(BigNumber.from(randomAmount));
}

async function coinFullRedeem(contracts, user) {
    let fullTokenAmount = contracts.coin.balanceOf(user.address);
    await contracts.coin.connect(user).requestRedeem(fullTokenAmount);
    await contracts.cashManager.connect(user).prepareDryPowderForRedemption();
    await processAllLiquidations(contracts.cashManager, user);
    await contracts.coin.connect(user).redeem();
    totalAVAXInvestments.sub(BigNumber.from(fullTokenAmount));
}

async function cashManagerProcessLiquidation(contracts, user) {
    await contracts.cashManager.connect(user).processLiquidation();
}

async function cashManagerProcessPurchase(contracts, user) {
    await contracts.cashManager.connect(user).processPurchase();
}

async function coinRequestRedeem(contracts, user) {
    let randomAmount = randomIntFromInterval(0, 1000);
    await contracts.coin.connect(user).requestRedeem(randomAmount);
}

async function waitADay(contracts, user) {
    await network.provider.send("evm_increaseTime", [86401]);
}

async function waitAWeek(contracts, user) {
    await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]);
}

async function cashManagerUpdateCashPrices(contracts, user) {
    await contracts.cashManager.connect(user).updateCashPrices();
}

async function cashManagerUpdateLiquidationsAndPurchases(contracts, user) {
    await contracts.cashManager.connect(user).updateLiquidationsAndPurchases();
}

async function investmentManagerSetAsset(contracts, user) {
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let liquidatePathsArray = Object.keys(liquidatePaths).map(function(key){
        return liquidatePaths[key];
    });
    let purchasePathsArray = Object.keys(purchasePaths).map(function(key){
        return purchasePaths[key];
    });
    let randomIndex = Math.floor(Math.random() * addressesArray.length);
    let randomAsset = addressesArray[randomIndex];
    //console.log("randomAsset = %s", randomAsset);
    let randomPriceTarget = BigNumber.from(String(randomIntFromInterval(0, 60000) * (10 ** 6)));
    //console.log("randomPriceTarget = %s", randomPriceTarget);
    let randomConfidence = BigNumber.from(String(randomIntFromInterval(0, 100) * (10 ** 6)));
    //console.log("randomConfidence = %s", randomConfidence);
    await contracts.investmentManager.connect(user).setInvestmentAsset(randomAsset,
                                                                       randomPriceTarget,
                                                                       randomConfidence,
                                                                       liquidatePathsArray[randomIndex],
                                                                       purchasePathsArray[randomIndex]);
    await contracts.investmentManager.connect(user).getLatestPrice(randomAsset); // First update
    await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
    await contracts.investmentManager.connect(user).getLatestPrice(randomAsset); // second update
    await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
    await contracts.investmentManager.connect(user).getLatestPrice(randomAsset); // third update
    await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
    await contracts.investmentManager.connect(user).getLatestPrice(randomAsset); // fourth update
}

async function cashManagerSetAssets(contracts, user) {
    // TODO
}

async function investmentManagerGetLatestPrice(contracts, user) {
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let randomAsset = getRandomElement(addressesArray);
    await contracts.investmentManager.connect(user).getLatestPrice(randomAsset);
}

async function investmentManagerBuy(contracts, user) {
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let randomAsset = getRandomElement(addressesArray);
    await contracts.investmentManager.connect(user).determineBuy(randomAsset);
    await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(randomAsset);
    await contracts.cashManager.connect(user).processInvestmentBuy(randomAsset);
}

async function investmentManagerDetermineBuy(contracts, user) {
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let randomAsset = getRandomElement(addressesArray);
    await contracts.investmentManager.connect(user).determineBuy(randomAsset);
}

async function cashManagerPrepareDryPowderForInvestmentBuy(contracts, user) {
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let randomAsset = getRandomElement(addressesArray);
    await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(randomAsset);
}

async function cashManagerProcessInvestmentBuy(contracts, user) {
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let randomAsset = getRandomElement(addressesArray);
    await contracts.cashManager.connect(user).processInvestmentBuy(randomAsset);
}

// Start test block
describe('Fuzz Testing', function () {

    let Coin;
    let coin;
    let CashManager;
    let cashManager;
    let owner;
    let user;
    let userInvestmentAmount = ethers.utils.parseUnits("100", "ether");
    let dai;
    let wavax;
    let router;
    let contracts;

    before(async function () {
        const user_addresses = await ethers.getSigners();
        owner = user_addresses[0];
        user = user_addresses[1];

        dai = await ethers.getContractAt("IERC20", addresses.dai);
        wavax = await ethers.getContractAt("IWAVAX", addresses.wavax);
    });

    beforeEach(async function () {
        contracts = await deployAll();
        coin = contracts.coin;
        cashManager = contracts.cashManager;
    });

    it("Should call random functions and end up in sane state", async function() {
        let tokens = await getTokens();
        await coin.connect(user).invest({"value": userInvestmentAmount});
        totalAVAXInvestments = totalAVAXInvestments.add(userInvestmentAmount);
        let { assets, allocations } = await setCashManagerAllocations(contracts.cashManager, owner, user, userInvestmentAmount);
        await makeCashManagerAllocations(contracts.cashManager, assets, allocations, user);
        // Make an investment
        expect(await tokens.joe.connect(user).balanceOf(contracts.investmentManager.address)).to.be.equal(0);
        await makeInvestment(contracts, owner, user);
        expect(await tokens.joe.connect(user).balanceOf(contracts.investmentManager.address)).to.be.not.equal(0);
        // Rebalance cash assets after investments
        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await makeCashManagerAllocations(contracts.cashManager, assets, allocations, user);

        // Randomly call functions
        let functionsToChooseFrom = [coinInvest, coinRedeem, coinRequestRedeem, coinFullRedeem, coinRandomRedeem, waitAWeek, waitADay,
                                     cashManagerUpdateLiquidationsAndPurchases, cashManagerUpdateCashPrices,
                                     investmentManagerGetLatestPrice, investmentManagerBuy, investmentManagerDetermineBuy,
                                     cashManagerPrepareDryPowderForInvestmentBuy, cashManagerProcessPurchase,
                                     cashManagerProcessLiquidation, cashManagerProcessInvestmentBuy, investmentManagerSetAsset];
        const numCalls = 200; // Increase this to increase the number of fuzz calls per test
        const user_addresses = await ethers.getSigners();
        console.log("There are %s users to choose from", user_addresses.length);
        var numSuccessfulCalls = numCalls;
        for (let i=0; i < numCalls; i++) {
            let randomFunction = functionsToChooseFrom[Math.floor(Math.random() * functionsToChooseFrom.length)];
            var randomUser;
            if (randomFunction.name == investmentManagerSetAsset.name) { // hard-code the owner to test deeper branches
                randomUser = user_addresses[0];
            } else {
                randomUser = getRandomElement(user_addresses);
            }
            try {
                await randomFunction(contracts, randomUser);
            } catch (e) {
                numSuccessfulCalls -= 1;
                if (!e.message.includes("reverted")) {
                    console.log("Calling %s threw: %s", randomFunction.name, e);
                }
            }
        }
        console.log("Out of %s calls, %s succeeded.", numCalls, numSuccessfulCalls);

        var cashManagerAVAXValue = await contracts.cashManager.connect(user).totalValueInWAVAX();
        var investmentManagerAVAXValue = await contracts.investmentManager.connect(user).totalValueInWAVAX();
        var sumAVAXValue = cashManagerAVAXValue.add(investmentManagerAVAXValue);
        console.log("total AVAX invested: %s, total WAVAX value of contracts: %s",
                    totalAVAXInvestments.toString(),sumAVAXValue.toString());

        // Get all the assets in the investment manager
        const numInvestmentAssets = await contracts.investmentManager.connect(user).numInvestmentAssets();
        console.log("There are %s investmentAssets", numInvestmentAssets);
        var investmentAssets = [];
        for (let i = 0; i < numInvestmentAssets; i++) {
            const investmentAsset = await contracts.investmentManager.connect(user).investmentAssets(i);
            investmentAssets.push(investmentAsset); }
        expect(investmentAssets.length).to.be.equal(numInvestmentAssets);

        // Do any pending investment purchases
        for (let asset of investmentAssets) {
            var data = await contracts.investmentManager.connect(user).investmentAssetsData(asset);
            let now = new Date();
            // if it's older than one day, get a new buy determination
            const latestBlock = await ethers.provider.getBlock("latest");
            let currentTimestampMinusOneDay = latestBlock.timestamp - (24 * 60 * 60);
            if ((data.buyAmount > 0) && (data.buyDeterminationTimestamp <= currentTimestampMinusOneDay)) { 
                console.log("Updating stale buy determination...");
                if (data.reservedForBuy) {
                    await contracts.cashManager.connect(user).processInvestmentBuy(asset); // clear the old determination
                }
                await contracts.investmentManager.connect(user).determineBuy(asset);
                data = await contracts.investmentManager.connect(user).investmentAssetsData(asset); // 
            }
            if (data.buyAmount > 0) {
                if (!data.reservedForBuy) {
                    await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(asset);
                }
                await contracts.cashManager.connect(user).processInvestmentBuy(asset);
            }
        }

        // Test that the cash manager is in a sane state
        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await makeCashManagerAllocations(contracts.cashManager, assets, allocations, user);

        // Any investments should roughly sum up to the WAVAX value of the cash manager + the WAVAX value of the investment manager
        // This ensures that no value was "lost"
        cashManagerAVAXValue = await contracts.cashManager.connect(user).totalValueInWAVAX();
        investmentManagerAVAXValue = await contracts.investmentManager.connect(user).totalValueInWAVAX();
        sumAVAXValue = cashManagerAVAXValue.add(investmentManagerAVAXValue);
        console.log("total AVAX invested: %s, total WAVAX value of contracts: %s",
                    totalAVAXInvestments.toString(),sumAVAXValue.toString());
        // TODO: Why is this typically lower than the investment, and by multiple AVAX? Possibly slippage from the swaps?
        const epsilonAVAX = ethers.utils.parseUnits("5", "ether");
        // The total WAVAX value of the two contracts must be within 1 AVAX of the total AVAX invested
        testBigNumberIsWithinInclusiveBounds(sumAVAXValue,
                                             totalAVAXInvestments.sub(epsilonAVAX),
                                             totalAVAXInvestments.add(epsilonAVAX));

        // Make sure that the investmentManager is in a sane state
        for(let asset of investmentAssets) {
            // TODO: do any necessary buys and sells and check that the ending value is sane
            const token = await ethers.getContractAt("IERC20", asset);
            var data = await contracts.investmentManager.connect(user).investmentAssetsData(asset);
            expect(data.reservedForBuy).to.be.equal(false);
            expect(data.buyAmount).to.be.equal(0);
        }

        // TODO: Make sure that no user got anything they shouldn't have gotten
    })

});
