// test/Airdrop.j0
// Load dependencies
import { expect } from "chai";
import { BigNumber } from "ethers";
import { ethers, network } from "hardhat";
import { addresses } from "../scripts/addresses";

// https://hardhat.org/tutorial/testing-contracts.html
// https://github.com/gnosis/mock-contract FOR HELP

// Start test block
describe('Test Library', function () {

    let owner;
    let user;
    let userInvestmentAmount = ethers.utils.parseUnits("100", "ether");
    let library;

    before(async function () {
        const user_addresses = await ethers.getSigners();
        owner = user_addresses[0];
        user = user_addresses[1];

        // This does not use deploy.ts because these internal functions won't be deployed to main net as a standalone contract
        const Library = await ethers.getContractFactory("ExposedLibraryForTesting");
        library = await Library.deploy();
        await library.deployed();
    });

    it ("Should calculate value percentages correctly", async function() {
        var result = await library.connect(user).valueIsWhatPercentOf(
            ethers.utils.parseUnits("1", "ether"), userInvestmentAmount);
        expect(result).to.equal(1 * (10**6));
        result = await library.connect(user).valueIsWhatPercentOf(ethers.utils.parseUnits("100", "ether"), userInvestmentAmount);
        expect(result).to.equal(100 * (10**6));
        result = await library.connect(user).valueIsWhatPercentOf(ethers.utils.parseUnits("45", "ether"), userInvestmentAmount);
        expect(result).to.equal(45 * (10**6));
    })

    it ("Should subtract percentages correctly", async function() {
        //var result = await library.connect(user).subtractPercentage(userInvestmentAmount, 1 * (10 ** 6)); // 1%
        //expect(result).to.equal(ethers.utils.parseUnits("99", "ether"));
        var result = await library.connect(user).subtractPercentage(userInvestmentAmount, 45 * (10 ** 6));
        expect(result).to.equal(ethers.utils.parseUnits("55", "ether"));
        result = await library.connect(user).subtractPercentage(ethers.utils.parseUnits("45", "ether"), 45 * (10 ** 6));
        expect(result).to.equal(ethers.utils.parseUnits("24.75", "ether"));
        // Subtract half a percent:
        //result = await library.connect(user).subtractPercentage(ethers.utils.parseUnits("45", "ether"), (5 * (10 ** 6)) / 10);
        //expect(result).to.equal(ethers.utils.parseUnits("44.775", "ether"));
    })

    it ("Should add percentages correctly", async function() {
        var result = await library.connect(user).addPercentage(userInvestmentAmount, 1 * (10 ** 6));
        expect(result).to.equal(ethers.utils.parseUnits("101", "ether"));
        result = await library.connect(user).addPercentage(userInvestmentAmount, 450 * (10 ** 6));
        expect(result).to.equal(ethers.utils.parseUnits("550", "ether"));
        result = await library.connect(user).addPercentage(ethers.utils.parseUnits("45", "ether"), 45 * (10 ** 6));
        expect(result).to.equal(ethers.utils.parseUnits("65.25", "ether"));
    })

    it ("Should take percentages correctly", async function() {
        var result = await library.connect(user).percentageOf(userInvestmentAmount, 1 * (10 ** 6));
        expect(result).to.equal(ethers.utils.parseUnits("1", "ether"));
        result = await library.connect(user).percentageOf(userInvestmentAmount, 450 * (10 ** 6));
        expect(result).to.equal(ethers.utils.parseUnits("450", "ether"));
        result = await library.connect(user).percentageOf(ethers.utils.parseUnits("45", "ether"), 45 * (10 ** 6));
        expect(result).to.equal(ethers.utils.parseUnits("20.25", "ether"));
        // Test half a percent: 0.5%
        result = await library.connect(user).percentageOf(ethers.utils.parseUnits("45", "ether"), (5 * (10 ** 6)) / 10);
        expect(result).to.equal(ethers.utils.parseUnits("0.225", "ether"));
    })

    it ("Should calculate the kelly bet correctly", async function() {
        var lossPercent = 20 * (10 ** 6); // Lose 20% in the loss scenario
        var gainPercent = 20 * (10 ** 6); // Gain 20% in the win scenario

        var result = await library.connect(user).kellyFraction(60 * (10 ** 6), lossPercent, gainPercent);
        expect(result).to.be.equal(BigNumber.from("100000000")); // 100%

        lossPercent = 10 * (10 ** 6);
        gainPercent = 100 * (10 ** 6);
        var result1 = await library.connect(user).kellyFraction(40 * (10 ** 6), lossPercent, gainPercent);
        expect(result1).to.be.equal(BigNumber.from("340000000")); // 340%

        // This test is special because the kelly criterion says not to bet anything
        var result2 = await library.connect(user).kellyFraction(BigNumber.from("60000000"), // 60% confidence
                                                                BigNumber.from("80000000"), // loss micro %
                                                                BigNumber.from("48040918")); // gain micro %
        expect(result2).to.be.equal(0);
    })

});
