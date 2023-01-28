// Load dependencies
import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers, network, upgrades } from "hardhat";
import { processAllLiquidations, setCashManagerAllocations, makeCashManagerAllocations } from "../scripts/cash-manager"
import { makeInvestment } from "../scripts/investment-manager"

// https://hardhat.org/tutorial/testing-contracts.html
// https://github.com/gnosis/mock-contract FOR HELP

// Start test block
describe('Test MaldenFeuersteinERC20', function () {

    let coin;
    let owner;
    let user;
    let userInvestmentAmount = ethers.utils.parseUnits("100", "ether");

    before(async function () {
        const user_addresses = await ethers.getSigners();
        owner = user_addresses[0];
        user = user_addresses[1];

        dai = await ethers.getContractAt("IERC20", addresses.dai);
        wavax = await ethers.getContractAt("IWAVAX", addresses.wavax);
    });

    beforeEach(async function () {
        const Coin: ContractFactory = await ethers.getContractFactory("MinterTestToken", signer);
        const coin: Contract = await upgrades.deployProxy(Coin, {'kind': 'uups'});
        await coin.deployed();
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

});
