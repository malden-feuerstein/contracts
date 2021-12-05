// test/Airdrop.j0
// Load dependencies
import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers, network, upgrades } from "hardhat";
import { addresses, liquidatePaths, purchasePaths, getTokens } from "../scripts/addresses";
import { deployAll } from "../scripts/deploy"
import { processAllPurchases,
         processAllLiquidations,
         balanceCashHoldingsTest,
         setCashManagerAllocations,
         makeCashManagerAllocations} from "../scripts/cash-manager";

// https://hardhat.org/tutorial/testing-contracts.html
// https://github.com/gnosis/mock-contract FOR HELP

async function makeInvestmentAndConvertToNotWAVAX(contracts, userInvestmentAmount, user, tokens, owner) {
    await contracts.coin.connect(user).invest({"value": userInvestmentAmount});
    await expect(await tokens.wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(userInvestmentAmount);

    // set the cashmanager so that it converts all wavax to other assets
    var testAssets = [addresses.weth, addresses.ampl, addresses.usdt, addresses.usdc, addresses.dai];
    var testAllocations = [20, 30, 20, 20, 10].map(x => x * (10 ** 6));
    var testLiquidationPaths = [liquidatePaths.weth,
                                liquidatePaths.ampl,
                                liquidatePaths.usdt,
                                liquidatePaths.usdc,
                                liquidatePaths.dai];
    var testPurchasePaths = [purchasePaths.weth,
                             purchasePaths.ampl,
                             purchasePaths.usdt,
                             purchasePaths.usdc,
                             purchasePaths.dai];
    await contracts.cashManager.connect(owner).setCashAllocations(testAssets,
                                                        testAllocations,
                                                        testLiquidationPaths,
                                                        testPurchasePaths);
    await expect(await tokens.wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(userInvestmentAmount);
    await contracts.cashManager.connect(user).updateCashPrices();
    await contracts.cashManager.connect(user).updateLiquidationsAndPurchases();
    await processAllPurchases(contracts.cashManager, user);
    await processAllLiquidations(contracts.cashManager, user);
    await expect(await tokens.wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
}

// Start test block
describe('Test InvestmentManager', function () {

    let owner;
    let user;
    let userInvestmentAmount = ethers.utils.parseUnits("100", "ether");
    let wavax;
    let contracts;
    let investmentManager;
    let usdt;
    let tokens;

    before(async function () {
        const user_addresses = await ethers.getSigners();
        owner = user_addresses[0];
        user = user_addresses[1];
        tokens = await getTokens();

        wavax = await ethers.getContractAt("IWAVAX", addresses.wavax);
        usdt = await ethers.getContractAt("IERC20", addresses.usdt);
    });

    beforeEach(async function () {
        contracts = await deployAll();
        investmentManager = contracts.investmentManager;
    });

    it ("Should not allow being initialized twice", async function() {
        await expect(investmentManager.connect(owner).initialize()).to.be.
            revertedWith("Initializable: contract is already initialized");
        await expect(investmentManager.connect(user).initialize()).to.be.
            revertedWith("Initializable: contract is already initialized");
    })

    it ("Should set investment targets", async function() {
        await expect(investmentManager.connect(user).assets(0)).to.be.
            revertedWith("Transaction reverted without a reason string");
        await expect(investmentManager.connect(user).setInvestmentAsset(wavax.address,
                                                                        260 * (10 ** 6),
                                                                        70 * (10 ** 6), // 70% confidence
                                                                        liquidatePaths.wavax,
                                                                        purchasePaths.wavax)).to.be.revertedWith(
                                                                        "Ownable: caller is not the owner");
        await expect(investmentManager.connect(user).assets(0)).to.be.
            revertedWith("Transaction reverted without a reason string");
        await investmentManager.connect(owner).setInvestmentAsset(wavax.address,
                                                                  260 * (10 ** 6),
                                                                  75 * (10 ** 6), // 75% confidence
                                                                  liquidatePaths.wavax,
                                                                  purchasePaths.wavax);
        expect(await investmentManager.connect(user).assets(0)).to.be.equal(wavax.address);
        await investmentManager.setInvestmentAsset(wavax.address,
                                                   260 * (10 ** 6),
                                                   70 * (10 ** 6), // 70% confidence
                                                   liquidatePaths.wavax,
                                                   purchasePaths.wavax);
        await expect(investmentManager.connect(user).assets(1)).to.be.
            revertedWith("Transaction reverted without a reason string");
    })

    it ("Should make a WAVAX buy investment with WAVAX in CashManager", async function() {
        await contracts.coin.connect(user).invest({"value": userInvestmentAmount});
        await expect(await wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(userInvestmentAmount);

        await expect(contracts.investmentManager.connect(user).processBuy(addresses.wavax)).to.be.
            revertedWith("This asset isn't in the investment manager.");
        await expect(investmentManager.connect(user).getLatestPrice(addresses.wavax)).to.be.
            revertedWith("asset is not in the chosen list of assets.");

        const token = await ethers.getContractAt("IERC20", addresses.wavax);
        await investmentManager.connect(owner).setInvestmentAsset(addresses.wavax,
                                                                  BigNumber.from("100000000"), // $100 AVAX price target, just above
                                                                  60 * (10 ** 6), // 60% confidence
                                                                  liquidatePaths.wavax,
                                                                  purchasePaths.wavax);
        await expect(investmentManager.connect(user).determineBuy(addresses.wbtc)).to.be.
            revertedWith("asset is not in the chosen list of assets.");
        await expect(investmentManager.connect(user).determineBuy(addresses.wavax)).to.be.
            revertedWith("Must have a minimum number of price samples.");
        await expect(contracts.investmentManager.connect(user).processBuy(addresses.wavax)).to.be.
            revertedWith("This asset doesn't have any authorized buy amount.");
        await investmentManager.connect(user).getLatestPrice(addresses.wavax); // First update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60]); // wait a day
        await expect(investmentManager.connect(user).getLatestPrice(addresses.wavax)).to.be.
            revertedWith("Can update price at most once per week.");
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 6]); // wait the remainer of a week
        await investmentManager.connect(user).getLatestPrice(addresses.wavax); // second update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.wavax); // third update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.wavax); // fourth update

        // the Kelly bet says it's not worth the risk at all
        var tx = await investmentManager.connect(user).determineBuy(addresses.wavax);
        var receipt = await tx.wait();
        expect(receipt.events[0].args[1]).to.equal(0); // betSize == 0
        // therefore, processing a buy on it shouldn't work
        await expect(contracts.investmentManager.connect(user).processBuy(addresses.wavax)).to.be.
            revertedWith("This asset doesn't have any authorized buy amount.");

        await investmentManager.connect(owner).setInvestmentAsset(addresses.wavax,
                                                                  BigNumber.from("10000000"), // $10 AVAX price target, far below
                                                                  60 * (10 ** 6), // 60% confidence
                                                                  liquidatePaths.wavax,
                                                                  purchasePaths.wavax);
        tx = await investmentManager.connect(user).determineBuy(addresses.wavax);
        receipt = await tx.wait();
        expect(receipt.events[0].args[1]).to.equal(0); // betSize == 0
        // therefore, processing a buy on it shouldn't work
        await expect(contracts.investmentManager.connect(user).processBuy(addresses.wavax)).to.be.
            revertedWith("This asset doesn't have any authorized buy amount.");

        // Set it to an intrinsicValue that will enable making a buy
        await investmentManager.connect(owner).setInvestmentAsset(addresses.wavax,
                                                                  BigNumber.from("2000000000"), // $2000 AVAX price target, far above
                                                                  60 * (10 ** 6), // 60% confidence
                                                                  liquidatePaths.wavax,
                                                                  purchasePaths.wavax);
        tx = await investmentManager.connect(user).determineBuy(addresses.wavax);
        receipt = await tx.wait();
        expect(receipt.events[0].args[1]).to.be.not.equal(0);
        var authorizedBuyAmount = receipt.events[0].args[1];

        // First reserve the WAVAX for the purchase
        await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.wavax);
        expect(await contracts.cashManager.connect(user).investmentReservedWAVAXAmount()).to.be.gt(0);
        await contracts.investmentManager.connect(user).processBuy(addresses.wavax);
        expect(await contracts.cashManager.connect(user).investmentReservedWAVAXAmount()).to.be.equal(0);
        expect(await wavax.connect(user).balanceOf(investmentManager.address)).to.equal(authorizedBuyAmount);

        await expect(investmentManager.connect(user).determineBuy(addresses.wavax)).to.be.revertedWith(
            "Cannot determine an asset buy more than once per week.");
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week

        // It should already be at the desired proportion of the bankroll and should not require any further purchases.
        tx = await investmentManager.connect(user).determineBuy(addresses.wavax);
        receipt = await tx.wait();
        expect(receipt.events[0].args[1]).to.equal(0); // betSize == 0
        // therefore, processing a buy on it shouldn't work
        await expect(contracts.investmentManager.connect(user).processBuy(addresses.wavax)).to.be.
            revertedWith("This asset doesn't have any authorized buy amount.");
    })

    it ("Should make a WAVAX buy investment with no WAVAX in CashManager", async function() {
        await makeInvestmentAndConvertToNotWAVAX(contracts, userInvestmentAmount, user, tokens, owner);

        await investmentManager.connect(owner).setInvestmentAsset(addresses.wavax,
                                                                  BigNumber.from("2000000000"), // $2000 AVAX price target
                                                                  60 * (10 ** 6), // 60% confidence
                                                                  liquidatePaths.wavax,
                                                                  purchasePaths.wavax);
        await investmentManager.connect(user).getLatestPrice(addresses.wavax); // First update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.wavax); // second update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.wavax); // third update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.wavax); // fourth update

        // Set it to an intrinsicValue that will enable making a buy
        var transaction = await investmentManager.connect(user).determineBuy(addresses.wavax);
        var receipt = await transaction.wait();
        expect(receipt.events[0].args[1]).to.be.not.equal(0);
        var authorizedBuyAmount = receipt.events[0].args[1];

        await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.wavax);
        await expect(await wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        await processAllLiquidations(contracts.cashManager, user);
        const endingWAVAXAmount = await wavax.connect(user).balanceOf(contracts.cashManager.address);
        await expect(endingWAVAXAmount).to.be.gte(authorizedBuyAmount);
        expect(await contracts.cashManager.connect(user).investmentReservedWAVAXAmount()).to.be.gt(0);
        await contracts.investmentManager.connect(user).processBuy(addresses.wavax);
        expect(await contracts.cashManager.connect(user).investmentReservedWAVAXAmount()).to.be.equal(0);
        expect(await wavax.connect(user).balanceOf(investmentManager.address)).to.equal(authorizedBuyAmount);
    })

    it ("Should make a JOE buy investment with no WAVAX in CashManager", async function() {
        await makeInvestmentAndConvertToNotWAVAX(contracts, userInvestmentAmount, user, tokens, owner);

        await investmentManager.connect(owner).setInvestmentAsset(addresses.joe,
                                                                  BigNumber.from("2000000000"), // $2000 AVAX price target
                                                                  60 * (10 ** 6), // 60% confidence
                                                                  liquidatePaths.joe,
                                                                  purchasePaths.joe);
        await investmentManager.connect(user).getLatestPrice(addresses.joe); // First update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.joe); // second update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.joe); // third update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.joe); // fourth update

        // Set it to an intrinsicValue that will enable making a buy
        var transaction = await investmentManager.connect(user).determineBuy(addresses.joe);
        var receipt = await transaction.wait();
        expect(receipt.events[0].args[1]).to.be.not.equal(0);
        var authorizedBuyAmount = receipt.events[0].args[1];

        await expect(contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.wavax)).to.be.
            revertedWith("CashManager: exists");
        await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.joe);
        await expect(contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.joe)).to.be.
            revertedWith("asset cannot already be reserved for this purchase.");
        await expect(await tokens.joe.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        await expect(await tokens.joe.connect(user).balanceOf(contracts.investmentManager.address)).to.equal(0);
        await processAllLiquidations(contracts.cashManager, user);
        const endingWAVAXAmount = await wavax.connect(user).balanceOf(contracts.cashManager.address);
        await expect(endingWAVAXAmount).to.be.gte(authorizedBuyAmount);
        await expect(await tokens.joe.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        expect(await contracts.cashManager.connect(user).investmentReservedWAVAXAmount()).to.be.gt(0);
        await contracts.investmentManager.connect(user).processBuy(addresses.joe);
        expect(await contracts.cashManager.connect(user).investmentReservedWAVAXAmount()).to.be.equal(0);
        await expect(await tokens.joe.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        await expect(await tokens.joe.connect(user).balanceOf(contracts.investmentManager.address)).to.not.equal(0);
        await expect(await tokens.wavax.connect(user).balanceOf(contracts.investmentManager.address)).to.equal(0);
    })

    it ("Should make a QI buy investment with partial WAVAX in CashManager", async function() {
        await contracts.coin.connect(user).invest({"value": userInvestmentAmount});
        await expect(await tokens.wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(userInvestmentAmount);

        // set the cashmanager so that it converts all wavax to other assets
        var testAssets = [addresses.wavax, addresses.weth, addresses.ampl, addresses.usdt, addresses.usdc, addresses.dai];
        var testAllocations = [5, 15, 30, 20, 20, 10].map(x => x * (10 ** 6));
        var testLiquidationPaths = [liquidatePaths.wavax,
                                    liquidatePaths.weth,
                                    liquidatePaths.ampl,
                                    liquidatePaths.usdt,
                                    liquidatePaths.usdc,
                                    liquidatePaths.dai];
        var testPurchasePaths = [purchasePaths.wavax,
                                 purchasePaths.weth,
                                 purchasePaths.ampl,
                                 purchasePaths.usdt,
                                 purchasePaths.usdc,
                                 purchasePaths.dai];
        await contracts.cashManager.connect(owner).setCashAllocations(testAssets,
                                                            testAllocations,
                                                            testLiquidationPaths,
                                                            testPurchasePaths);
        await expect(await tokens.wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(userInvestmentAmount);
        await contracts.cashManager.connect(user).updateCashPrices();
        await contracts.cashManager.connect(user).updateLiquidationsAndPurchases();
        await processAllPurchases(contracts.cashManager, user);
        await processAllLiquidations(contracts.cashManager, user);
        await expect(await tokens.wavax.connect(user).balanceOf(contracts.cashManager.address)).to.not.equal(0);

        await investmentManager.connect(owner).setInvestmentAsset(addresses.qi,
                                                                  BigNumber.from("2000000000"), // $2000 JOE price target
                                                                  90 * (10 ** 6), // 60% confidence
                                                                  liquidatePaths.qi,
                                                                  purchasePaths.qi);
        await investmentManager.connect(user).getLatestPrice(addresses.qi); // First update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.qi); // second update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.qi); // third update
        await network.provider.send("evm_increaseTime", [24 * 60 * 60 * 7]); // wait a week
        await investmentManager.connect(user).getLatestPrice(addresses.qi); // fourth update
        await expect(await tokens.wavax.connect(user).balanceOf(contracts.cashManager.address)).to.not.equal(0);

        // Set it to an intrinsicValue that will enable making a buy
        var transaction = await investmentManager.connect(user).determineBuy(addresses.qi);
        var receipt = await transaction.wait();
        expect(receipt.events[0].args[1]).to.be.not.equal(0);
        var authorizedBuyAmount = receipt.events[0].args[1];
        await expect(await tokens.wavax.connect(user).balanceOf(contracts.cashManager.address)).to.not.equal(0);

        await expect(contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.wavax)).to.be.
            revertedWith("CashManager: exists");
        await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.qi);
        await expect(contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.qi)).to.be.
            revertedWith("asset cannot already be reserved for this purchase.");
        await expect(await tokens.qi.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        await expect(await tokens.qi.connect(user).balanceOf(contracts.investmentManager.address)).to.equal(0);
        await processAllLiquidations(contracts.cashManager, user);
        const endingWAVAXAmount = await wavax.connect(user).balanceOf(contracts.cashManager.address);
        await expect(endingWAVAXAmount).to.be.gte(authorizedBuyAmount);
        await expect(await tokens.qi.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        expect(await contracts.cashManager.connect(user).investmentReservedWAVAXAmount()).to.be.gt(0);
        await contracts.investmentManager.connect(user).processBuy(addresses.qi);
        expect(await contracts.cashManager.connect(user).investmentReservedWAVAXAmount()).to.be.equal(0);
        await expect(await tokens.qi.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        await expect(await tokens.qi.connect(user).balanceOf(contracts.investmentManager.address)).to.not.equal(0);
        await expect(await tokens.wavax.connect(user).balanceOf(contracts.investmentManager.address)).to.equal(0);
        // re-balance the cash manager and check that the balances are right
        await balanceCashHoldingsTest(contracts, user, testAssets, testAllocations);
    })

});
