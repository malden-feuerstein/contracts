// test/Airdrop.j0
// Load dependencies
import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers, network, upgrades } from "hardhat";
import { addresses, liquidatePaths, purchasePaths } from "../scripts/addresses";
import { deployAll } from "../scripts/deploy";
import { processAllLiquidations } from "../scripts/cash-manager"

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
        await expect(coin.initialize(contracts.cashManager.address, contracts.investmentManager.address)).to.be.
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
        processAllLiquidations(contracts.cashManager, user);
        await expect(await coin.connect(user).balanceOf(user.address)).to.equal(userInvestmentAmount);
        await expect(await wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(userInvestmentAmount);
        await expect(await wavax.connect(user).balanceOf(coin.address)).to.equal(0);
        await expect(await coin.provider.getBalance(coin.address)).to.equal(0); // Has no AVAX because it's WAVAX
        //const beforeBalance = await coin.provider.getBalance(user.address);
        //console.log("user AVAX before redeem: ", beforeBalance.toString());
        await coin.connect(user).redeem();
        //const afterBalance = await coin.provider.getBalance(user.address);
        //console.log("user AVAX after redeem: ", afterBalance.toString());
        await expect(await coin.provider.getBalance(coin.address)).to.equal(0);
        await expect(await coin.connect(user).balanceOf(user.address)).to.equal(0);
        await expect(await coin.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        await expect(await wavax.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
        await expect(await wavax.connect(user).balanceOf(coin.address)).to.equal(0);
        await expect(await wavax.connect(user).balanceOf(user.address)).to.equal(userInvestmentAmount);
    })

});
