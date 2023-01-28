import { 
  Contract, 
  ContractFactory 
} from "ethers"
import { ethers, upgrades } from "hardhat"
import { addresses, joeRouterAddress, joeFactoryAddress } from "./addresses"

async function deployAll(signer?) { // This will be used to deploy to main net
    if (!signer) {
        signer = await ethers.getSigners()[0];
    }

    const ValueHelpers: ContractFactory = await ethers.getContractFactory("ValueHelpers", signer);
    const valueHelpers: Contract = await upgrades.deployProxy(ValueHelpers, {'kind': 'uups'});
    await valueHelpers.deployed();

    const SwapRouter: ContractFactory = await ethers.getContractFactory("SwapRouter", signer);
    const swapRouter: Contract = await upgrades.deployProxy(SwapRouter, {'kind': 'uups'});
    await swapRouter.deployed();

    const InvestmentManager: ContractFactory = await ethers.getContractFactory("InvestmentManager", signer);
    const investmentManager: Contract = await upgrades.deployProxy(InvestmentManager, {'kind': 'uups'});
    await investmentManager.deployed();

    const CashManager: ContractFactory = await ethers.getContractFactory("CashManager", signer);
    const cashManager: Contract = await upgrades.deployProxy(CashManager,
                                                             {'kind': 'uups'});
    await cashManager.deployed();

    const Coin: ContractFactory = await ethers.getContractFactory("MaldenFeuersteinERC20", signer);
    const coin: Contract = await upgrades.deployProxy(Coin, {'kind': 'uups'});
    await coin.deployed();

    await cashManager.setAddresses(addresses.wavax,
                                   joeRouterAddress,
                                   swapRouter.address,
                                   coin.address,
                                   valueHelpers.address,
                                   investmentManager.address,
                                   addresses.usdt);

    await investmentManager.setAddresses(addresses.wavax,
                                         swapRouter.address,
                                         valueHelpers.address,
                                         addresses.usdt,
                                         cashManager.address,
                                         joeRouterAddress,
                                         coin.address);
    await swapRouter.setAddresses(joeFactoryAddress);
    await valueHelpers.setAddresses(addresses.wavax,
                                    cashManager.address,
                                    swapRouter.address,
                                    investmentManager.address);
    await coin.setAddresses(addresses.wavax,
                            cashManager.address,
                            valueHelpers.address,
                            investmentManager.address);

    const contracts = {
        coin: coin,
        valueHelpers: valueHelpers,
        addresses: addresses,
        swapRouter: swapRouter,
        cashManager: cashManager,
        investmentManager: investmentManager
    };

    return contracts;
}

export { deployAll };

const main = async(): Promise<any> => {
    await deployAll();
}

//main()
//.then(() => process.exit(0))
//.catch(error => {
  //console.error(error)
  //process.exit(1)
//})
