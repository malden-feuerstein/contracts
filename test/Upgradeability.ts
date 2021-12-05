// test/Airdrop.j0
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
describe('Test Upgradeability', function () {

    let owner;
    let user;
    let wavax;
    let contracts;

    before(async function () {
        const user_addresses = await ethers.getSigners();
        owner = user_addresses[0];
        user = user_addresses[1];

        wavax = await ethers.getContractAt("IWAVAX", addresses.wavax);
    });

    beforeEach(async function () {
        contracts = await deployAll();
    });

    it ("Should allow upgrading contracts", async function() {
        // I want to know that I can change function implementations, change constant values, and add new functions
        const CashManagerV2 = await ethers.getContractFactory("CashManagerV2");
        const cashManagerV2 = await upgrades.upgradeProxy(contracts.cashManager.address, CashManagerV2);

        // I can add a new function
        // I can change the value of an initialized constant. initialize() is NOT called again.
        await expect(await cashManagerV2.connect(user).newBlockEveryNMicroseconds()).to.be.equal(2000);
        // I cannot directly get the 42 from this transaction because it is neither pure nor view, see here:
        // https://ethereum.stackexchange.com/a/88122/3901
        const newFunctionOutput = await cashManagerV2.connect(user).thisIsANewFunction();
        await expect(await cashManagerV2.connect(user).newBlockEveryNMicroseconds()).to.be.equal(5000);
        const tx = await cashManagerV2.connect(user).newFunctionThatEmits();
        const receipt = await tx.wait();
        expect(receipt.events[0].args[0]).to.be.equal(42);

        // I can change the return value of an existing function
        const oldFunctionChangedOutput = await cashManagerV2.connect(user).numPurhcasesToProcess();
        expect(oldFunctionChangedOutput).to.be.equal(222);

        // I can change the behavior of an existing function
        await expect(cashManagerV2.connect(owner).setCashAllocations([], [], [], [])).to.be.revertedWith("");

        // I can change a constant property's value as well as its visibility (private to public)
        await expect(await cashManagerV2.connect(user).ONE_HUNDRED_PERCENT()).to.be.equal(ethers.utils.parseUnits("100", "ether"));

    })

});
