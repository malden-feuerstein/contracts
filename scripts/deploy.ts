import { 
  Contract, 
  ContractFactory 
} from "ethers"
import { ethers, upgrades } from "hardhat"

async function deployAll() { // This will be used to deploy to main net
  
    const NFT: ContractFactory = await ethers.getContractFactory("XanderNFTs");
    const nft: Contract = await NFT.deploy();
    await nft.deployed();

    const SwapRouter: ContractFactory = await ethers.getContractFactory("SwapRouter");
    const swapRouter: Contract = await upgrades.deployProxy(SwapRouter, {'kind': 'uups'});
    await swapRouter.deployed();

    const InvestmentManager: ContractFactory = await ethers.getContractFactory("InvestmentManager");
    const investmentManager: Contract = await upgrades.deployProxy(InvestmentManager, [swapRouter.address], {'kind': 'uups'});

    const CashManager: ContractFactory = await ethers.getContractFactory("CashManager");
    const cashManager: Contract = await upgrades.deployProxy(CashManager,
                                                             [swapRouter.address, investmentManager.address],
                                                             {'kind': 'uups'});
    await cashManager.deployed();

    await investmentManager.deployed();
    await investmentManager.setCashManagerAddress(cashManager.address);

    const Coin: ContractFactory = await ethers.getContractFactory("MaldenFeuersteinERC20");
    const coin: Contract = await upgrades.deployProxy(Coin, [cashManager.address, investmentManager.address], {'kind': 'uups'});
    await coin.deployed();

    cashManager.setCoinAddress(coin.address);

    const contracts = {
        coin: coin,
        nft: nft,
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
