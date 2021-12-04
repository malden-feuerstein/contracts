import { 
  Contract, 
  ContractFactory,
  BigNumber
} from "ethers"
import { ethers, network, upgrades } from "hardhat";
import { expect } from "chai";
import { addresses, liquidatePaths, purchasePaths, getTokens } from "./addresses";
import { processAllLiquidations } from "./cash-manager"

// Convenience function for making initial investments after a user investment and cash assets have been diversified
export async function makeInvestment(contracts, owner, user) {
    let investmentManager = contracts.investmentManager;
    let tokens = await getTokens();
    const wavax = tokens.wavax;
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

    //await expect(contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.wavax)).to.be.
        //revertedWith("This asset isn't in the investment manager.");
    await contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.joe);
    //await expect(contracts.cashManager.connect(user).prepareDryPowderForInvestmentBuy(addresses.joe)).to.be.
        //revertedWith("asset cannot already be reserved for this purchase.");
    await expect(await tokens.joe.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
    await expect(await tokens.joe.connect(user).balanceOf(contracts.investmentManager.address)).to.equal(0);
    await processAllLiquidations(contracts.cashManager, user);
    const endingWAVAXAmount = await wavax.connect(user).balanceOf(contracts.cashManager.address);
    await expect(endingWAVAXAmount).to.be.gte(authorizedBuyAmount);
    await expect(await tokens.joe.connect(user).balanceOf(contracts.cashManager.address)).to.equal(0);
    await contracts.investmentManager.connect(user).processBuy(addresses.joe);
}
