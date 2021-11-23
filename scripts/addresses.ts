import { ethers } from "hardhat";

// TODO: Rather than hard-code, get these from here:
// https://github.com/traderjoe-xyz/joe-tokenlists/blob/main/joe.tokenlist.json
export const addresses = {
    wavax: ethers.utils.getAddress("0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7"),
    dai: ethers.utils.getAddress("0xd586E7F844cEa2F87f50152665BCbc2C279D8d70"),
    joeRouter: ethers.utils.getAddress("0x60aE616a2155Ee3d9A68541Ba4544862310933d4"),
    wbtc: ethers.utils.getAddress("0x50b7545627a5162F82A992c33b87aDc75187B218"),
    weth: ethers.utils.getAddress("0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB"),
    usdt: ethers.utils.getAddress("0xc7198437980c041c805A1EDcbA50c1Ce5db95118"),
    usdc: ethers.utils.getAddress("0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664"),
    ampl: ethers.utils.getAddress("0x027dbcA046ca156De9622cD1e2D907d375e53aa7"),
    joe: ethers.utils.getAddress("0x6e84a6216ea6dacc71ee8e6b0a5b7322eebc0fdd"),
    qi: ethers.utils.getAddress("0x8729438eb15e2c8b576fcc6aecda6a148776c0f5"),
}

export async function getTokens() {
    return {
        wavax: await ethers.getContractAt("IERC20", addresses.wavax),
        dai: await ethers.getContractAt("IERC20", addresses.dai),
        wbtc: await ethers.getContractAt("IERC20", addresses.wbtc),
        weth: await ethers.getContractAt("IERC20", addresses.weth),
        usdt: await ethers.getContractAt("IERC20", addresses.usdt),
        usdc: await ethers.getContractAt("IERC20", addresses.usdc),
        ampl: await ethers.getContractAt("IERC20", addresses.ampl),
        joe: await ethers.getContractAt("IERC20", addresses.joe),
        qi: await ethers.getContractAt("IERC20", addresses.qi),
    }
}

export const liquidatePaths = {
    wavax: [],
    dai: [addresses.dai, addresses.wavax],
    wbtc: [addresses.wbtc, addresses.wavax],
    weth: [addresses.weth, addresses.wavax],
    usdt: [addresses.usdt, addresses.wavax],
    usdc: [addresses.usdc, addresses.wavax],
    ampl: [addresses.ampl, addresses.wavax],
    joe: [addresses.joe, addresses.wavax],
    qi: [addresses.qi, addresses.wavax],
}

export const purchasePaths = {
    wavax: [],
    dai: [addresses.wavax, addresses.dai],
    wbtc: [addresses.wavax, addresses.wbtc],
    weth: [addresses.wavax, addresses.weth],
    usdt: [addresses.wavax, addresses.usdt],
    usdc: [addresses.wavax, addresses.usdc],
    ampl: [addresses.wavax, addresses.ampl],
    joe: [addresses.wavax, addresses.joe],
    qi: [addresses.wavax, addresses.qi]
}
