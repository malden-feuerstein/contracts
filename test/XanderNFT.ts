// test/Airdrop.js
// Load dependencies
import { expect } from "chai";
import { ethers } from "hardhat";
import { deployAll } from "../scripts/deploy"

// https://hardhat.org/tutorial/testing-contracts.html
// https://github.com/gnosis/mock-contract FOR HELP

// Start test block
describe('Test XanderNFTs', function () {

    let nft;
    let addresses;
    let owner;
    let user;

    before(async function () {
        addresses = await ethers.getSigners()
        owner = addresses[0]
        user = addresses[1]
    });

    beforeEach(async function () {
        const contracts = await deployAll();
        nft = contracts.nft;
    });

    it("Should mint an NFT", async function() {
        await expect(await nft.connect(owner).balanceOf(owner.address)).to.equal(0);
        //await expect(nft.connect(user).awardItem(owner.address)).to.be.revertedWith("Only owner can call");
        await expect(await nft.connect(owner).balanceOf(owner.address)).to.equal(0);
        await nft.connect(owner).awardItem(owner.address);
        await expect(await nft.connect(user).balanceOf(owner.address)).to.equal(1);
    })

});
