import { 
  Contract, 
  ContractFactory 
} from "ethers"
import { ethers, upgrades } from "hardhat"
import { deployAll } from "./deploy"
import { setCashManagerAllocations } from "./cash-manager"
import { LedgerSigner } from "@ethersproject/hardware-wallets"

async function deployMainnet() { // This will be used to deploy to main net
    console.log(ethers.provider);
    const ledger = await new LedgerSigner(ethers.provider, "hid", "m/44'/60'/0'/0");

    let contracts = await deployAll(ledger);
    console.log(contracts);
    console.log("InvestmentManager: %s", contracts.investmentManager.address);
    console.log("CashManager: %s", contracts.cashManager.address);
    console.log("MALD: %s", contracts.coin.address);
    console.log("ValueHelpers: %s", contracts.valueHelpers.address);
    console.log("SwapRouter: %s", contracts.swapRouter.address);

    await setCashManagerAllocations(contracts.cashManager);
}

const main = async(): Promise<any> => {
    await deployMainnet();
}

main()
.then(() => process.exit(0))
.catch(error => {
  console.error(error)
  process.exit(1)
})
