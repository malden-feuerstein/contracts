// test/Airdrop.j0
// Load dependencies
import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers, network, upgrades } from "hardhat";
import { addresses, liquidatePaths, purchasePaths } from "../scripts/addresses";
import { deployAll } from "../scripts/deploy";
import { processAllPurchases,
         processAllLiquidations,
         testBigNumberIsWithinInclusiveBounds,
         balanceCashHoldingsTest,
         makeCashManagerAllocations,
         setCashManagerAllocations,
         testTokenAmountWithinBounds } from "../scripts/cash-manager";


async function mineNBlocks(n) {
    for (let i = 0; i < n; i++) {
        await network.provider.send("evm_mine"); // mine a block
    }
}

// https://hardhat.org/tutorial/testing-contracts.html
// https://github.com/gnosis/mock-contract FOR HELP

// Start test block
describe('Test CashManager', function () {

    let coin;
    let cashManager;
    let owner;
    let user;
    let userInvestmentAmount = ethers.utils.parseUnits("100", "ether");
    let dai;
    let wavax;
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

    it ("Should not allow being initialized twice", async function() {
        await expect(cashManager.initialize()).to.be.
            revertedWith("Initializable: contract is already initialized");
    })
    // TODO: Add a test that upgrading a variable like

    it ("Should have the right cash allocations", async function() {
        await expect(cashManager.connect(user).assets(0)).to.be.revertedWith("Transaction reverted without a reason string");

        var testAssets = [];
        var testAllocations = [100 * (10 ** 6)];
        var testLiquidationPaths = [];
        var testPurchasePaths = [];
        await expect(cashManager.connect(user).setCashAllocations(testAssets,
                                                                     testAllocations,
                                                                     testLiquidationPaths,
                                                                     testPurchasePaths)).to.be.
            revertedWith("Ownable: caller is not the owner");
        await expect(cashManager.connect(owner).setCashAllocations(testAssets,
                                                                      testAllocations,
                                                                      testLiquidationPaths,
                                                                      testPurchasePaths)).to.be.
            revertedWith("Assets and percentages arrays must be the same length.");
        testAssets = [ethers.utils.getAddress(addresses.wavax)];
        testLiquidationPaths = [liquidatePaths.wavax];
        testPurchasePaths = [purchasePaths.wavax];
        await cashManager.connect(owner).setCashAllocations(testAssets,
                                                               testAllocations,
                                                               testLiquidationPaths,
                                                               testPurchasePaths);
        const cashAsset = await cashManager.assets(0);
        expect(cashAsset == addresses.wavax);

        // Make an initial investment
        await coin.connect(user).invest({"value": userInvestmentAmount});
        await expect(await wavax.connect(user).balanceOf(cashManager.address)).to.equal(userInvestmentAmount);
        await cashManager.connect(user).updateCashPrices();

        testAssets = [addresses.wavax,
                      addresses.wbtc,
                      addresses.weth,
                      addresses.ampl,
                      addresses.usdt,
                      addresses.usdc,
                      addresses.dai];
        testAllocations = [10, 10, 10, 10, 20, 20, 20].map(x => x * (10 ** 6));
        testLiquidationPaths = [liquidatePaths.wavax,
                                liquidatePaths.wbtc,
                                liquidatePaths.weth,
                                liquidatePaths.ampl,
                                liquidatePaths.usdt,
                                liquidatePaths.usdc,
                                liquidatePaths.dai];
        testPurchasePaths = [purchasePaths.wavax,
                             purchasePaths.wbtc,
                             purchasePaths.weth,
                             purchasePaths.ampl,
                             purchasePaths.usdt,
                             purchasePaths.usdc,
                             purchasePaths.dai];
        await cashManager.connect(owner).setCashAllocations(testAssets,
                                                               testAllocations,
                                                               testLiquidationPaths,
                                                               testPurchasePaths);
        expect(await cashManager.connect(user).numAssets()).to.equal(7);
        expect(await cashManager.connect(user).numAssets()).to.not.equal(6);
        expect(await cashManager.connect(user).numAssets()).to.not.equal(8);
        await expect(await wavax.connect(user).balanceOf(cashManager.address)).to.equal(userInvestmentAmount);
        await expect(cashManager.connect(user).updateLiquidationsAndPurchases()).to.be.revertedWith(
            "Asset is missing from the cashAssetsPrices.");
        await makeCashManagerAllocations(contracts, testAssets, testAllocations, user);
        await testTokenAmountWithinBounds(addresses.wavax, user, cashManager.address, "10");

        testAssets = [addresses.weth, addresses.ampl, addresses.usdt, addresses.usdc, addresses.dai];
        testAllocations = [20, 10, 23, 24, 23].map(x => x * (10 ** 6));
        testLiquidationPaths = [liquidatePaths.weth,
                                liquidatePaths.ampl,
                                liquidatePaths.usdt,
                                liquidatePaths.usdc,
                                liquidatePaths.dai];
        testPurchasePaths = [purchasePaths.weth,
                             purchasePaths.ampl,
                             purchasePaths.usdt,
                             purchasePaths.usdc,
                             purchasePaths.dai];
        // This call liquidates WBTC to WAVAX, so the WAVAX will no longer be 10
        await cashManager.connect(owner).setCashAllocations(testAssets,
                                                               testAllocations,
                                                               testLiquidationPaths,
                                                               testPurchasePaths);
        await expect(await cashManager.connect(user).numAssets()).to.equal(5);
        await expect(await (await ethers.getContractAt("IERC20", addresses.wbtc)).balanceOf(cashManager.address)).to.be.equal(0);
        await cashManager.connect(user).updateCashPrices();
        await expect(cashManager.connect(user).updateLiquidationsAndPurchases()).to.be.revertedWith(
            "Can update cash balances only once per day.");
        // On a real network, time and blocks will increase roughly in synchrony, but it's very inefficient to mine a day's
        // worth of blocks here
        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await mineNBlocks(30);
        await expect(cashManager.connect(user).updateLiquidationsAndPurchases()).to.be.revertedWith(
            "Cash asset prices are older than one minute.");
        await cashManager.connect(user).updateCashPrices();
        await cashManager.connect(user).updateLiquidationsAndPurchases();
        await expect(await cashManager.connect(user).numPurhcasesToProcess()).to.be.equal(4);
        await expect(await cashManager.connect(user).numLiquidationsToProcess()).to.be.equal(0);
        await processAllLiquidations(cashManager, user);
        await processAllPurchases(cashManager, user);
        //// TODO: WAVAX balance may not be exactly 0 here even though it was liquidated
        await expect(await (await ethers.getContractAt("IERC20", addresses.wbtc)).balanceOf(cashManager.address)).to.be.equal(0);

        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await cashManager.connect(user).updateCashPrices();
        await cashManager.connect(user).updateCashPrices();
        await expect(await wavax.connect(user).balanceOf(cashManager.address)).to.equal(ethers.utils.parseUnits("0", "ether"));
        await cashManager.connect(user).updateLiquidationsAndPurchases();
        // There won't be anything to update because the allotment percentages haven't changed and prices are very close
        await expect(await cashManager.connect(user).numPurhcasesToProcess()).to.be.equal(0);
        await expect(await cashManager.connect(user).numLiquidationsToProcess()).to.be.equal(0);
        // TODO: Test the asset balances at the end of the swapping
        // TODO: If this is holdling billions of dollars, what do the rounding errors look like compounded over many
        //      updates?
    })
    // TODO: Test the scenario where the user makes the first investment
    // TODO: Test the scenario where new users make investments after it was previously balanced
    //
    // TODO: Add a test that triggers a processLiquidation() (liquidate something other than WAVAX)
    it ("Should do full and partial liquidations correctly", async function() {
        await expect(cashManager.connect(user).assets(0)).to.be.revertedWith("Transaction reverted without a reason string");

        // Make an initial investment
        await coin.connect(user).invest({"value": userInvestmentAmount});
        await expect(await wavax.connect(user).balanceOf(cashManager.address)).to.equal(userInvestmentAmount);
        await cashManager.connect(user).updateCashPrices();

        await setCashManagerAllocations(cashManager, owner, user, userInvestmentAmount);
        await cashManager.connect(user).updateCashPrices();
        await cashManager.connect(user).updateLiquidationsAndPurchases();
        // Although I have more WAVAX than 10%, it's not counted as a liquidation
        await expect(await cashManager.connect(user).numPurhcasesToProcess()).to.be.equal(5);
        await expect(await cashManager.connect(user).numLiquidationsToProcess()).to.be.equal(0);
        await expect(cashManager.connect(user).processLiquidation()).to.be.revertedWith(
            "There are no liquidations queued from a call to updateLiquidationsAndPurchases().");
        await expect(await wavax.connect(user).balanceOf(cashManager.address)).to.equal(userInvestmentAmount);
        await expect(await cashManager.connect(user).numLiquidationsToProcess()).to.be.equal(0);
        await processAllPurchases(cashManager, user);
        await testTokenAmountWithinBounds(wavax.address, user, cashManager.address, "20");

        // remove wbtc, add ampl, and reduce dai from 15% to 10%
        const testAssets = [addresses.wavax, addresses.weth, addresses.ampl, addresses.usdt, addresses.usdc, addresses.dai];
        const testAllocations = [20, 15, 20, 20, 15, 10].map(x => x * (10 ** 6));
        const testLiquidationPaths = [liquidatePaths.wavax,
                                liquidatePaths.weth,
                                liquidatePaths.ampl,
                                liquidatePaths.usdt,
                                liquidatePaths.usdc,
                                liquidatePaths.dai];
        const testPurchasePaths = [purchasePaths.wavax,
                             purchasePaths.weth,
                             purchasePaths.ampl,
                             purchasePaths.usdt,
                             purchasePaths.usdc,
                             purchasePaths.dai];
        // This call liquidates WBTC to WAVAX, so the WAVAX will no longer be 10
        await cashManager.connect(owner).setCashAllocations(testAssets,
                                                            testAllocations,
                                                            testLiquidationPaths,
                                                            testPurchasePaths);
        await expect(await cashManager.connect(user).numAssets()).to.equal(6);
        await expect(await (await ethers.getContractAt("IERC20", addresses.wbtc)).balanceOf(cashManager.address)).to.be.equal(0);
        await cashManager.connect(user).updateCashPrices();
        await expect(cashManager.connect(user).updateLiquidationsAndPurchases()).to.be.revertedWith(
            "Can update cash balances only once per day.");
        // On a real network, time and blocks will increase roughly in synchrony, but it's very inefficient to mine a day's
        // worth of blocks here
        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await mineNBlocks(30);
        await expect(cashManager.connect(user).updateLiquidationsAndPurchases()).to.be.revertedWith(
            "Cash asset prices are older than one minute.");
        await cashManager.connect(user).updateCashPrices();
        await cashManager.connect(user).updateLiquidationsAndPurchases();
        await expect(await cashManager.connect(user).numPurhcasesToProcess()).to.be.equal(1);
        await expect(await cashManager.connect(user).numLiquidationsToProcess()).to.be.equal(1);
        const originalDAIAmount = await dai.connect(user).balanceOf(cashManager.address);
        await processAllLiquidations(cashManager, user);
        const finalDAIAmount = await dai.connect(user).balanceOf(cashManager.address);
        await processAllPurchases(cashManager, user);
        const finalWAVAXAmount = await wavax.connect(user).balanceOf(cashManager.address);
        await expect(finalWAVAXAmount).to.not.equal(0);
        const finalWAVAXPercent = await contracts.valueHelpers.connect(user).assetPercentageOfCashManager(wavax.address);
        const finalDAIPercent = await contracts.valueHelpers.connect(user).assetPercentageOfCashManager(dai.address);
        const finalAMPLPercent = await contracts.valueHelpers.connect(user).assetPercentageOfCashManager(addresses.ampl);
        testBigNumberIsWithinInclusiveBounds(finalDAIPercent, ethers.BigNumber.from("9000000"), ethers.BigNumber.from("11000000"));
        testBigNumberIsWithinInclusiveBounds(finalWAVAXPercent, ethers.BigNumber.from("19000000"), ethers.BigNumber.from("21000000"));
        testBigNumberIsWithinInclusiveBounds(finalAMPLPercent, ethers.BigNumber.from("19000000"), ethers.BigNumber.from("21000000"));
        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await balanceCashHoldingsTest(contracts, user, testAssets, testAllocations);
    })

});
