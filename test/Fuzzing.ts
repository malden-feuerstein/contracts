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
// TODO: Should be able to randomly pause and unpause the contracts at any time and ignore all reverted transactions while paused

// This should be the same as the value in Library.sol
const PERCENTAGE_DECIMALS = 6;
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
    console.log("%s invested %s", user.address, randomAmountInWei.toString());
    totalAVAXInvestments = totalAVAXInvestments.add(randomAmountInWei);
}

async function coinRedeem(contracts, user) {
    let result = await contracts.coin.connect(user).redeem();
    console.log(result);
    let amountRedeemed = result.events[0].args[0];
    totalAVAXInvestments.sub(amountRedeemed);
    console.log("%s redeemed %s MALD on a coinRedeem() call", user.address, amountRedeemed.toString());
}

async function coinRandomRedeem(contracts, user) {
    let randomAmount = randomIntFromInterval(0, 1000);
    await contracts.coin.connect(user).requestRedeem(randomAmount);
    await contracts.cashManager.connect(user).prepareDryPowderForRedemption();
    await processAllLiquidations(contracts.cashManager, user);
    await contracts.coin.connect(user).approve(contracts.coin.address, randomAmount);
    await contracts.coin.connect(user).redeem();
    totalAVAXInvestments = totalAVAXInvestments.sub(randomAmount);
    console.log("%s redeemed %s", user.address, randomAmount.toString());
}

// This attempts to get out all of a user's funds, and it attempts to always succeed
async function coinFullRedeem(contracts, user) {
    let fullTokenAmount = await contracts.coin.balanceOf(user.address);
    let expectedEndingTokenAmount = BigNumber.from("0");
    await network.provider.send("evm_increaseTime", [86401]); // Make sure it's been a day since the investment took place
    if (fullTokenAmount > 0) {
        let result = await contracts.coin.connect(user).getAuthorizedRedemptionAmounts(user.address);
        let maldenCoinAmount = result[0];
        let avaxAmount = result[1];
        if (maldenCoinAmount.eq(BigNumber.from("0"))) {
            expect(avaxAmount).to.be.equal(BigNumber.from("0"));
        }
        if (avaxAmount.eq(BigNumber.from("0"))) { // Only request redemption if it's not already authorized
            expect(maldenCoinAmount).to.be.equal(BigNumber.from("0"));
            await contracts.coin.connect(user).requestRedeem(fullTokenAmount);
        } else {
            expectedEndingTokenAmount = fullTokenAmount.sub(maldenCoinAmount);
            fullTokenAmount = maldenCoinAmount;
        }
        const authorizations = await contracts.coin.getAuthorizedRedemptionAmounts(user.address);
        console.log("CashManager liquidations...");
        if (authorizations[1] > 0) { // Don't try to liquidate anything from the CashManager if it has nothing in it
            await contracts.cashManager.connect(user).prepareDryPowderForRedemption();
            await processAllLiquidations(contracts.cashManager, user);
        }

        // Do this only if there isn't enough WAVAX in the CashManager
        console.log(result);
        console.log("InvestmentManager liquidations...");
        if (authorizations[2] > 0) {
            await contracts.investmentManager.connect(user).prepareDryPowderForRedemption();
            await processAllLiquidations(contracts.investmentManager, user);
        }

        const userAVAXBefore = await contracts.coin.provider.getBalance(user.address);
        await contracts.coin.connect(user).approve(contracts.coin.address, fullTokenAmount);
        let contractsValueBefore = (await contracts.valueHelpers.connect(user).cashManagerTotalValueInWAVAX()).add(
            await contracts.valueHelpers.connect(user).investmentManagerTotalValueInWAVAX());
        const contractMALDBefore = await contracts.coin.connect(user).balanceOf(contracts.coin.address);
        let tx = await contracts.coin.connect(user).redeem();
        let receipt = await tx.wait()
        let redeemedAmount = receipt.events[0].args[0];
        let maldenRedeemedAmount = receipt.events[0].args[1];
        const contractMALDAfter = await contracts.coin.connect(user).balanceOf(contracts.coin.address);
        let contractsValueAfter = (await contracts.valueHelpers.connect(user).cashManagerTotalValueInWAVAX()).add(
            await contracts.valueHelpers.connect(user).investmentManagerTotalValueInWAVAX());
        const userAVAXAfter = await contracts.coin.provider.getBalance(user.address);
        totalAVAXInvestments = totalAVAXInvestments.sub(fullTokenAmount);
        expect(await contracts.coin.balanceOf(user.address)).to.be.equal(expectedEndingTokenAmount);
        // Check not merely that it's greater than, but check that it went up by the desired amount
        // This assumes a max transaction cost of 1 AVAX
        expect(userAVAXAfter).to.be.gt(userAVAXBefore.add(redeemedAmount).sub(ethers.utils.parseUnits("1", "ether")));
        expect(userAVAXAfter).to.be.gt(userAVAXBefore);
        expect(contractsValueBefore).to.be.gt(contractsValueAfter);
        expect(contractsValueAfter).to.be.gt(contractsValueBefore.sub(redeemedAmount).sub(ethers.utils.parseUnits("1", "ether")));
        expect(contractsValueAfter).to.be.lt(contractsValueBefore.sub(redeemedAmount).add(ethers.utils.parseUnits("1", "ether")));
        expect(contractMALDAfter).to.be.eq(contractMALDBefore.add(maldenRedeemedAmount));
        expect(await contracts.coin.connect(user).balanceOf(user.address)).to.be.equal(0);
        console.log("%s redeemed %s", user.address, fullTokenAmount.toString());
    }
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
    console.log("%s updated cash manager prices.", user.address);
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
    let randomPriceTarget = BigNumber.from(String(randomIntFromInterval(0, 60000) * (10 ** PERCENTAGE_DECIMALS)));
    //console.log("randomPriceTarget = %s", randomPriceTarget);
    let randomConfidence = BigNumber.from(String(randomIntFromInterval(0, 100) * (10 ** PERCENTAGE_DECIMALS)));
    //console.log("randomConfidence = %s", randomConfidence);
    console.log("investmentManagerSetAsset:");
    console.log(randomAsset);
    console.log(liquidatePathsArray[randomIndex]);
    console.log(purchasePathsArray[randomIndex]);
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
    console.log("%s set investment asset %s", user.address, randomAsset);
}

async function cashManagerSetAssets(contracts, user) {
    // TODO
}

// Send MALD tokens from one user to another
async function sendMALD(contracts, user) {
    let userMALDAmount = await contracts.coin.connect(user).balanceOf(user.address);
    if (userMALDAmount.gt(BigNumber.from("0"))) {
        let randomDivisor = randomIntFromInterval(1, 10);
        let sendAmount = userMALDAmount.div(BigNumber.from(randomDivisor));
        let recepientUser = getRandomElement(await ethers.getSigners());
        await contracts.coin.connect(user).transfer(recepientUser.address, sendAmount);
        console.log("sendMALD %s sent %s MALD to %s", user.address, sendAmount, recepientUser.address);
    }
}

async function testMakeCashManagerAllocations(contracts, user) {
    // TODO: How do I know what the assets and the allocations are?
    //await makeCashManagerAllocations(contracts.cashManager, assets, allocations, user);
}

async function investmentManagerGetLatestPrice(contracts, user) {
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let randomAsset = getRandomElement(addressesArray);
    await contracts.investmentManager.connect(user).getLatestPrice(randomAsset);
    console.log("%s got latest investment manager price on %s", user.address, randomAsset);
}

async function investmentManagerBuy(contracts, user) {
    console.log("investmentManagerBuy...");
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let randomAsset = getRandomElement(addressesArray);
    console.log(randomAsset);
    await contracts.investmentManager.connect(user).determineBuy(randomAsset);
    await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(randomAsset);
    await contracts.investmentManager.connect(user).processBuy(randomAsset);
    console.log("%s made investment manager buy of %s", user.address, randomAsset);
}

async function investmentManagerDetermineBuy(contracts, user) {
    console.log("investmentManagerDetermineBuy...");
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let randomAsset = getRandomElement(addressesArray);
    console.log(randomAsset);
    await contracts.investmentManager.connect(user).determineBuy(randomAsset);
    console.log("%s made an InvestmentManager buy determination on asset %s", user.address, randomAsset);
}

async function investmentManagerDetermineSell(contracts, user) {
    console.log("investmentManagerDetermineSell...");
    let addressesArray = Object.keys(addresses).map(function(key){
        return addresses[key];
    });
    let randomAsset = getRandomElement(addressesArray);
    console.log(randomAsset);
    await contracts.investmentManager.connect(user).determineSell(randomAsset);
    console.log("%s made an InvestmentManager sell determination on asset %s", user.address, randomAsset);
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
    await contracts.investmentManager.connect(user).processBuy(randomAsset);
    console.log("%s made investment manager buy of %s", user.address, randomAsset);
}

// Start test block
describe('Fuzz Testing', function () {

    let Coin;
    let coin;
    let CashManager;
    let cashManager;
    let owner;
    let user;
    let userInvestmentAmount = ethers.utils.parseUnits("10", "ether");
    let dai;
    let wavax;
    let router;
    let contracts;
    let PERCENTAGE_DECIMALS;

    before(async function () {
        const user_addresses = await ethers.getSigners();
        owner = user_addresses[0];
        user = user_addresses[1];

        dai = await ethers.getContractAt("IERC20", addresses.dai);
        wavax = await ethers.getContractAt("IWAVAX", addresses.wavax);

        const Library = await ethers.getContractFactory("ExposedLibraryForTesting");
        const library = await Library.deploy();
        await library.deployed();
        PERCENTAGE_DECIMALS = await library.connect(user).PERCENTAGE_DECIMALS();
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
        await makeCashManagerAllocations(contracts, assets, allocations, user);
        // Make an investment
        expect(await tokens.joe.connect(user).balanceOf(contracts.investmentManager.address)).to.be.equal(0);
        await makeInvestment(contracts, owner, user);
        expect(await tokens.joe.connect(user).balanceOf(contracts.investmentManager.address)).to.be.not.equal(0);
        // Rebalance cash assets after investments
        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await makeCashManagerAllocations(contracts, assets, allocations, user);

        // Randomly call functions
        let functionsToChooseFrom = [coinInvest, coinRedeem, coinRequestRedeem, coinFullRedeem, coinRandomRedeem, waitAWeek, waitADay,
                                     cashManagerUpdateLiquidationsAndPurchases, cashManagerUpdateCashPrices,
                                     investmentManagerGetLatestPrice, investmentManagerBuy, investmentManagerDetermineBuy,
                                     cashManagerPrepareDryPowderForInvestmentBuy, cashManagerProcessPurchase,
                                     cashManagerProcessLiquidation, cashManagerProcessInvestmentBuy, investmentManagerSetAsset,
                                     sendMALD, investmentManagerDetermineSell];
        // I want it to sometimes execute a small number of calls because this tends to produce outcomes with small AVAX amounts,
        // I want coverage of both large and small AVAX amounts
        const numCalls = randomIntFromInterval(20, 400); // Increase this to increase the number of fuzz calls per test
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
                if (randomFunction.name == coinFullRedeem.name, randomFunction.name == sendMALD.name) {
                    console.log("%s failed with: %s", randomFunction.name, e);
                } else if (!e.message.includes("reverted")) {
                    console.log("Calling %s threw: %s", randomFunction.name, e);
                } else if (e.message.includes("underflow") || e.message.includes("overflow")) {
                    console.log("Calling %s caused arithmetic error: %s", randomFunction.name, e);
                }
            }
        }
        console.log("Out of %s calls, %s succeeded.", numCalls, numSuccessfulCalls);

        var cashManagerAVAXValue = await contracts.valueHelpers.connect(user).cashManagerTotalValueInWAVAX();
        var investmentManagerAVAXValue = await contracts.valueHelpers.connect(user).investmentManagerTotalValueInWAVAX();
        var sumAVAXValue = cashManagerAVAXValue.add(investmentManagerAVAXValue);
        console.log("total AVAX invested: %s, total WAVAX value of contracts: %s",
                    totalAVAXInvestments.toString(),sumAVAXValue.toString());

        // Get all the assets in the investment manager
        const numInvestmentAssets = await contracts.investmentManager.connect(user).numAssets();
        console.log("There are %s investmentAssets", numInvestmentAssets);
        var investmentAssets = [];
        for (let i = 0; i < numInvestmentAssets; i++) {
            const investmentAsset = await contracts.investmentManager.connect(user).assets(i);
            investmentAssets.push(investmentAsset); }
        expect(investmentAssets.length).to.be.equal(numInvestmentAssets);

        // Do any pending investment purchases
        // wait a week so that I can definitely determine a buy for all assets
        await network.provider.send("evm_increaseTime", [7 * 24 * 60 * 60]); 
        for (let asset of investmentAssets) {
            var data = await contracts.investmentManager.connect(user).investmentAssetsData(asset);
            console.log(data);
            let now = new Date();
            // if it's older than one day, get a new buy determination
            const latestBlock = await ethers.provider.getBlock("latest");
            let currentTimestampMinusOneDay = latestBlock.timestamp - (24 * 60 * 60);
            console.log("data.buyDeterminationTimestamp = %s", data.buyDeterminationTimestamp.toString());
            console.log("currentTimestampMinusOneDay", currentTimestampMinusOneDay.toString());
            if ((data.buyAmount > 0) && (data.buyDeterminationTimestamp <= currentTimestampMinusOneDay)) {
                console.log("Updating stale buy determination...");
                if (data.reservedForBuy) {
                    await contracts.investmentManager.connect(user).processBuy(asset); // clear the old determination
                }
                await contracts.investmentManager.connect(user).determineBuy(asset);
                data = await contracts.investmentManager.connect(user).investmentAssetsData(asset); //
            }
            if (data.buyAmount > 0) {
                if (!data.reservedForBuy) {
                    await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(asset);
                }
                await contracts.investmentManager.connect(user).processBuy(asset);
            }
        }

        // Any investments should roughly sum up to the WAVAX value of the cash manager + the WAVAX value of the investment manager
        // This ensures that no value was "lost"
        cashManagerAVAXValue = await contracts.valueHelpers.connect(user).cashManagerTotalValueInWAVAX();
        investmentManagerAVAXValue = await contracts.valueHelpers.connect(user).investmentManagerTotalValueInWAVAX();
        sumAVAXValue = cashManagerAVAXValue.add(investmentManagerAVAXValue);
        console.log("total AVAX invested: %s, total WAVAX value of contracts: %s,\nCashManager: %s, InvestmentManager: %s",
                    totalAVAXInvestments.toString(),sumAVAXValue.toString(),
                   cashManagerAVAXValue.toString(), investmentManagerAVAXValue.toString());

        // Test that the cash manager is in a sane state
        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await makeCashManagerAllocations(contracts, assets, allocations, user);

        const Library = await ethers.getContractFactory("ExposedLibraryForTesting");
        const library = await Library.deploy();
        await library.deployed();
        // The smaller the total value in the funds, the larger the percentage of funds that will be eroded through swap slippages
        // TODO: Ideally this wouldn't be a fixed percentage, but would be a percentage that is a function of the size of the
        // funds as well as the number of swaps performed.
        const epsilonAVAX = await library.percentageOf(totalAVAXInvestments, BigNumber.from((1 * (10 ** PERCENTAGE_DECIMALS))));
        console.log("+/- 1% is %s AVAX", epsilonAVAX);
        // The total WAVAX value of the two contracts must be within 1 AVAX of the total AVAX invested
        testBigNumberIsWithinInclusiveBounds(sumAVAXValue,
                                             totalAVAXInvestments.sub(epsilonAVAX),
                                             totalAVAXInvestments.add(epsilonAVAX));

        // Make sure that the investmentManager is in a sane state
        for(let asset of investmentAssets) {
            const token = await ethers.getContractAt("IERC20", asset);
            var data = await contracts.investmentManager.connect(user).investmentAssetsData(asset);
            expect(data.reservedForBuy).to.be.equal(false);
            expect(data.buyAmount).to.be.equal(0);
        }
        expect(await contracts.coin.connect(user).totalSupply()).to.be.equal(ethers.utils.parseUnits("100000", "ether"));
        expect(await contracts.coin.connect(user).circulatingSupply()).to.be.lte(ethers.utils.parseUnits("100000", "ether"));
        expect(await contracts.coin.connect(user).circulatingSupply()).to.be.lte(ethers.utils.parseUnits("100", "ether"));
        expect(await contracts.cashManager.connect(user).investmentReservedWAVAXAmount()).to.be.equal(0);
        // TODO: Print a list of all cash holdings and all investment holdings and their percentages, print the determined kelly
        // criterion for each investment asset

        // Every user should be able to fully redeem. Iterate through the users and redeem if they have non-zero tokens
        const randomNumber = randomIntFromInterval(0, 99);
        if (randomNumber < 50) { // Set the contracts to a paused state with a 50% chance
            console.log("Pausing the contracts...");
            await contracts.coin.connect(owner).pause();
            await contracts.investmentManager.connect(owner).pause();
            await contracts.cashManager.connect(owner).pause();
        }
        console.log("Redeeming all user investments...");
        for (let localUser of await user_addresses) {
            await coinFullRedeem(contracts, localUser);
            expect(await contracts.coin.connect(localUser).balanceOf(localUser.address)).to.be.equal(0);
        }

        // Test that there are no outstanding MALD approvals between the contracts
        expect(await contracts.coin.allowance(contracts.coin.address, contracts.cashManager.address)).to.be.equal(0);
        expect(await contracts.coin.allowance(contracts.cashManager.address, contracts.coin.address)).to.be.equal(0);
        expect(await contracts.coin.allowance(contracts.cashManager.address, contracts.investmentManager.address)).to.be.equal(0);
        expect(await contracts.coin.allowance(contracts.investmentManager.address, contracts.cashManager.address)).to.be.equal(0);
        expect(await contracts.coin.allowance(contracts.coin.address, contracts.investmentManager.address)).to.be.equal(0);
        expect(await contracts.coin.allowance(contracts.investmentManager.address, contracts.coin.address)).to.be.equal(0);

        // Test that there are no outsanding WAVAX approvals between the contracts
        expect(await wavax.allowance(contracts.coin.address, contracts.cashManager.address)).to.be.equal(0);
        // FIXME: There is a lot of dangling allowance of WAVAX from the cashManager to the Coin
        //expect(await wavax.allowance(contracts.cashManager.address, contracts.coin.address)).to.be.equal(0);
        // FIXME: There is a lot of dangling allowance of WAVAX from the cashManager to the investmentManager
        //expect(await wavax.allowance(contracts.cashManager.address, contracts.investmentManager.address)).to.be.equal(0);
        expect(await wavax.allowance(contracts.investmentManager.address, contracts.cashManager.address)).to.be.equal(0);
        expect(await wavax.allowance(contracts.coin.address, contracts.investmentManager.address)).to.be.equal(0);
        // FIXME: This one is also triggered frequently
        //expect(await wavax.allowance(contracts.investmentManager.address, contracts.coin.address)).to.be.equal(0);
    })

});
