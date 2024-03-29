// test
// Load dependencies
import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers, network, upgrades } from "hardhat";
import { addresses, liquidatePaths, purchasePaths, getTokens } from "../scripts/addresses";
import { deployAll } from "../scripts/deploy";
import { processAllLiquidations, setCashManagerAllocations, makeCashManagerAllocations } from "../scripts/cash-manager"
import { makeInvestment } from "../scripts/investment-manager"

// https://hardhat.org/tutorial/testing-contracts.html
// https://github.com/gnosis/mock-contract FOR HELP

// Start test block
describe('Test MaldenFeuersteinERC20', function () {

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
        console.log("owner", owner);
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
        await expect(coin.initialize()).to.be.
            revertedWith("Initializable: contract is already initialized");
    })

    it ("Should have the correct total supply", async function() {
        const supplyInWei = await coin.connect(user).totalSupply();
        expect(supplyInWei).to.equal(ethers.BigNumber.from("100000000000000000000000"));
    })

    it("Should have the right starting balance", async function() {
        expect(await coin.balanceOf(owner.address)).to.equal(0);
        expect(await coin.balanceOf(coin.address)).to.equal(ethers.BigNumber.from("100000000000000000000000"));
        expect(await coin.connect(user).balanceOf(coin.address)).to.equal(ethers.BigNumber.from("100000000000000000000000"));
    })

    it("Should have a low investment limit for the testing period", async function() {
        await coin.connect(user).invest({"value": ethers.utils.parseUnits("50", "ether")});
        await expect(coin.connect(user).invest({"value": ethers.utils.parseUnits("70", "ether")})).to.be.revertedWith(
            "Testing phase hard limit reached.");
    })

    it("Should work with a small investment", async function() {
        const smallInvestmentValue = ethers.utils.parseUnits("1", "ether");
        await coin.connect(user).invest({"value": smallInvestmentValue});
        let { assets, allocations } = await setCashManagerAllocations(contracts.cashManager);
        await makeCashManagerAllocations(contracts, assets, allocations, user);
    })

    it("Should have the correct circulating supply", async function() {
        await coin.connect(user).invest({"value": ethers.utils.parseUnits("50", "ether")});
        expect(await coin.connect(user).circulatingSupply()).to.be.equal(ethers.utils.parseUnits("50", "ether"));
        expect(await coin.connect(user).balanceOf(user.address)).to.be.equal(ethers.utils.parseUnits("50", "ether"));
        await coin.connect(user).invest({"value": ethers.utils.parseUnits("10", "ether")});
        expect(await coin.connect(user).circulatingSupply()).to.be.equal(ethers.utils.parseUnits("60", "ether"));
        expect(await coin.connect(user).balanceOf(user.address)).to.be.equal(ethers.utils.parseUnits("60", "ether"));
        await network.provider.send("evm_increaseTime", [86401]); // wait a day

        await coin.connect(user).requestRedeem(ethers.utils.parseUnits("45", "ether"));
        await contracts.cashManager.connect(user).prepareDryPowderForRedemption();
        await coin.connect(user).approve(coin.address, ethers.utils.parseUnits("45", "ether"));
        await coin.connect(user).redeem();
        expect(await coin.connect(user).circulatingSupply()).to.be.equal(ethers.utils.parseUnits("15", "ether"));

        await coin.connect(user).requestRedeem(ethers.utils.parseUnits("15", "ether"));
        await contracts.cashManager.connect(user).prepareDryPowderForRedemption();
        await coin.connect(user).approve(coin.address, ethers.utils.parseUnits("15", "ether"));
        await coin.connect(user).redeem();
        expect(await coin.connect(user).circulatingSupply()).to.be.equal(ethers.utils.parseUnits("0", "ether"));
    })

    it("Should not allow immediate redemption, redemption should work after speed bump", async function() {
        const balance = await coin.provider.getBalance(user.address);
        // https://docs.ethers.io/v4/api-utils.html#ether-strings-and-wei
        await expect(await coin.provider.getBalance(coin.address)).to.equal(0); // Contract starts with no AVAX
        await expect(await wavax.connect(user).balanceOf(coin.address)).to.equal(0);
        await expect(coin.connect(user).redeem()).to.be.
            revertedWith("Not authorized to redeem anything.");
        await expect(coin.connect(user).requestRedeem(userInvestmentAmount)).to.be.
            revertedWith("Must own at least as many tokens as attempting to redeem.");

        await expect(await coin.connect(user).totalSupply()).to.equal(ethers.BigNumber.from("100000000000000000000000"));
        await coin.connect(user).invest({"value": userInvestmentAmount});
        await expect(await coin.connect(user).totalSupply()).to.equal(ethers.utils.parseUnits("100000", "ether"));
        await expect(await coin.connect(user).circulatingSupply()).to.equal(ethers.utils.parseUnits("100", "ether"));
        await expect(await coin.provider.getBalance(coin.address)).to.equal(0);
        await expect(await wavax.connect(user).balanceOf(cashManager.address)).to.equal(userInvestmentAmount);
        await expect(coin.connect(user).redeem()).to.be.
            revertedWith("Not authorized to redeem anything.");
        await expect(coin.connect(user).requestRedeem(userInvestmentAmount)).to.be.
            revertedWith("Must wait at least one day to redeem an investment.");
        await expect(await coin.connect(user).balanceOf(user.address)).to.equal(userInvestmentAmount);

        // From https://ethereum.stackexchange.com/questions/86633/time-dependent-tests-with-hardhat
        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await coin.connect(user).approve(coin.address, userInvestmentAmount);
        await expect(coin.connect(user).redeem()).to.be.revertedWith("Not authorized to redeem anything.");
        await expect(await coin.connect(user).balanceOf(user.address)).to.equal(userInvestmentAmount);

        await coin.connect(user).requestRedeem(userInvestmentAmount);
        //await expect(coin.connect(user).redeem()).to.be.revertedWith();
        await contracts.cashManager.connect(user).prepareDryPowderForRedemption();
        await processAllLiquidations(contracts.cashManager, user);
        await expect(await coin.connect(user).balanceOf(user.address)).to.equal(userInvestmentAmount);
        await expect(await wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(userInvestmentAmount);
        await expect(await wavax.connect(user).balanceOf(coin.address)).to.equal(0);
        await expect(await coin.provider.getBalance(coin.address)).to.equal(0); // Has no AVAX because it's WAVAX
        let userAVAXBalanceBefore = await coin.provider.getBalance(user.address);
        await coin.connect(user).redeem();
        await expect(await coin.provider.getBalance(coin.address)).to.equal(0);
        await expect(await coin.connect(user).balanceOf(user.address)).to.equal(0);
        await expect(await coin.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        await expect(await wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        await expect(await wavax.connect(user).balanceOf(coin.address)).to.equal(0);
        await expect(await wavax.connect(user).balanceOf(user.address)).to.equal(0);
        await expect(await coin.provider.getBalance(user.address)).to.be.gt(userAVAXBalanceBefore);
    })

    it("Should be pausable", async function() {
        let tokens = await getTokens();
        await coin.connect(user).invest({"value": userInvestmentAmount});
        let { assets, allocations } = await setCashManagerAllocations(contracts.cashManager);
        await makeCashManagerAllocations(contracts, assets, allocations, user);
        // Make an investment
        expect(await tokens.joe.connect(user).balanceOf(contracts.investmentManager.address)).to.be.equal(0);
        await makeInvestment(contracts, owner, user);
        expect(await tokens.joe.connect(user).balanceOf(contracts.investmentManager.address)).to.be.not.equal(0);
        // Rebalance cash assets after investments
        await network.provider.send("evm_increaseTime", [86401]); // wait a day
        await makeCashManagerAllocations(contracts, assets, allocations, user);

        // Pause InvestmentManager
        expect(await contracts.investmentManager.connect(user).paused()).to.be.equal(false);
        await expect(contracts.investmentManager.connect(user).pause()).to.be.revertedWith("'Ownable: caller is not the owner");
        expect(await contracts.investmentManager.connect(user).paused()).to.be.equal(false);
        await contracts.investmentManager.connect(owner).pause();
        expect(await contracts.investmentManager.connect(user).paused()).to.be.equal(true);
        await expect(contracts.investmentManager.connect(owner).getLatestPrice(addresses.joe)).
            to.be.revertedWith("Pausable: paused");
        await expect(contracts.investmentManager.connect(owner).determineBuy(addresses.joe)).
            to.be.revertedWith("Pausable: paused");

        // Pause CashManager
        expect(await contracts.cashManager.connect(user).paused()).to.be.equal(false);
        await expect(contracts.cashManager.connect(user).pause()).to.be.revertedWith("'Ownable: caller is not the owner");
        expect(await contracts.cashManager.connect(user).paused()).to.be.equal(false);
        await contracts.cashManager.connect(owner).pause();
        expect(await contracts.cashManager.connect(user).paused()).to.be.equal(true);
        await expect(contracts.cashManager.connect(owner).updateCashPrices()).to.be.revertedWith("Pausable: paused");
        await expect(contracts.cashManager.connect(owner).updateLiquidationsAndPurchases()).to.be.revertedWith("Pausable: paused");

        // Pause token
        expect(await contracts.coin.connect(user).paused()).to.be.equal(false);
        await expect(contracts.coin.connect(user).pause()).to.be.revertedWith("'Ownable: caller is not the owner");
        expect(await contracts.coin.connect(user).paused()).to.be.equal(false);
        await contracts.coin.connect(owner).pause();
        expect(await contracts.coin.connect(user).paused()).to.be.equal(true);
        await expect(contracts.coin.connect(owner).invest()).to.be.revertedWith("Pausable: paused");
        try {
            await contracts.coin.connect(owner).invest()
        } catch (e: unknown) {
        }

        // Test that redemption still works
        expect(await coin.connect(user).balanceOf(user.address)).to.be.equal(userInvestmentAmount);
        await coin.connect(user).approve(coin.address, userInvestmentAmount);
        await coin.connect(user).requestRedeem(userInvestmentAmount);
        await contracts.cashManager.connect(user).prepareDryPowderForRedemption();
        await processAllLiquidations(contracts.cashManager, user);
        // redeem() needs to pull not only from the cash manager, but also from the investment manager
        await contracts.investmentManager.connect(user).prepareDryPowderForRedemption();
        await processAllLiquidations(contracts.investmentManager, user);
        expect(await tokens.dai.connect(user).balanceOf(user.address)).to.be.equal(0);
        expect(await tokens.usdc.connect(user).balanceOf(user.address)).to.be.equal(0);
        expect(await tokens.usdt.connect(user).balanceOf(user.address)).to.be.equal(0);
        expect(await tokens.weth.connect(user).balanceOf(user.address)).to.be.equal(0);
        expect(await tokens.wbtc.connect(user).balanceOf(user.address)).to.be.equal(0);
        expect(await tokens.ampl.connect(user).balanceOf(user.address)).to.be.equal(0);
        expect(await wavax.connect(user).balanceOf(contracts.cashManager.address)).to.be.gt(0);
        expect(await wavax.connect(user).balanceOf(contracts.investmentManager.address)).to.be.gt(0);
        const userAVAXBefore = await coin.provider.getBalance(user.address);
        // https://github.com/fvictorio/hardhat-examples/blob/master/reading-events/scripts/getEventsFromTx.js
        let tx = await coin.connect(user).redeem();
        let receipt = await tx.wait()
        let redeemedAmount = receipt.events[0].args[0];
        expect(await wavax.connect(user).balanceOf(contracts.cashManager.address)).to.be.equal(0);
        expect(await wavax.connect(user).balanceOf(contracts.investmentManager.address)).to.be.equal(0);
        expect(await contracts.valueHelpers.connect(user).investmentManagerTotalValueInWAVAX()).to.be.equal(0);
        expect(await contracts.valueHelpers.connect(user).cashManagerTotalValueInWAVAX()).to.be.equal(0);
        const userAVAXAfter = await coin.provider.getBalance(user.address);
        // This assumes a max transaction cost of 1 AVAX
        expect(userAVAXAfter).to.be.gt(userAVAXBefore.add(redeemedAmount).sub(ethers.utils.parseUnits("1", "ether")));
        expect(await wavax.connect(user).balanceOf(user.address)).to.be.equal(0);
    })

});
