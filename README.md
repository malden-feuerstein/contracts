### Introduction
Malden Feuerstein is a set of EVM-compatible solidity contracts to be deployed initially on the Avalanche C-Chain. Malden Feuerstein is a non-custodial value investment fund. Anyone can put money into the fund and have it governed by the investment rules encoded in the contracts. It is unique compared to smart contract investment enablers such as [dHedge](https://www.dhedge.org) or [Syndicate](https://syndicate.io) in that the investment thesis and principles are codified rules on the blockchain. Furthermore, no fees are charged. The management of the funds is decentralized and anyone can update its prices and allocations. Initially, the only centralized component is the list of assets that are considered for investment by the decentralized investment fund. The contracts use OpenZeppelin to achieve UUPS upgradeability.

### Functionality Overview
- MaldenFeuersteinERC20.sol is an ERC20 token (MALD). Tokens can be received by sending AVAX to the contract. That AVAX is sent to CashManager.sol to be diversified into the cash holding portfolio. This contract also enables redeeming the MALD tokens for the equivalent percentage of all cash assets and investment assets in the contract.
- CashManager.sol holds all assets until they're ready to be invested. It has percentage allotments to diversify assets across a set of cash assets, such as USDT, USDC, DAI, etc.
- InvestmentManager.sol is responsible for collecting market prices on assets that are being watched. It enforces the Kelly criterion for bet sizing and when to invest in assets based on market conditions. 

### Install
- `brew install go`
- Install and build [avalanchego](https://github.com/ava-labs/avalanchego)
    - Install and build avash: `go build`
- `brew tap ethereum/ethereum`
- `brew install solidity`
- `nvm install 16`
- `nvm use 16`
- `nvm alias default 16`
- `pip3 install slither-analyzer` for static analysis
- `npm install -g solhint`
- Running `slither .` with slither 0.8.1 is working on macOS on this hardhat project with hardhat compiler specified as 0.7.6 and command line also 0.7.6
- On macOS I had to build solc compiler from source according to [this](https://docs.soliditylang.org/en/latest/installing-solidity.html#building-from-source) instructions to have a local solc that works with both my project and slither. Homebrew solidity 0.8.9 and 0.8.10 compile correctly for Apple Silicon, but the 0.7.6 package does not. Download the release source code .zip and create a file commit_hash.txt with the commit hash of the release in it. Add a file prerelease.txt to the root directory for it to compile a release build.
- For mythx static analyzer, `pip3 install py-solc-x`, then open Python and `import solcx; solcx.import_installed_solc()` described [here](https://solcx.readthedocs.io/en/latest/version-management.html#importing-already-installed-versions)
- Install the [mythril](https://github.com/ConsenSys/mythril) static analyzer: This takes a while: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh; rustup default nightly; brew install leveldb gfortran automake autoconf openblas; OPENBLAS="$(brew --prefix openblas)" pip3 install mythril`

### Run
- This was set up from the guide [here](https://docs.avax.network/build/tutorials/smart-contracts/using-hardhat-with-the-avalanche-c-chain)
- `cd ~/dev/avash & ./avash` to start the local test net of five nodes, this is the same as `runscript scripts/five_node_staking.lua`. The avash test network is only if you plan on testing on a local, empty network. If you use hardhat to fork the mainnet, there's no need to run a local instance of avash.
- `yarn accounts --network local`
- `yarn balances --network local`
- `yarn fund-cchain-addresses` to send AVAX to the test accounts
- `yarn compile`
- `yarn deploy --network local`
- `yarn console --network local`
- `yarn test --network local` to run unit tests
- Switch any of the above to `--network hardhat` to run it on a local fork of the Avalanche mainnet

### Test
- `yarn test <test/test_file.ts>` or `yarn test` to run all the tests
- To show unit test coverage statistics: `npx hardhat coverage`
- To show static analysis warnings: `yarn analyze`
- To show linter warnings: `yarn lint`

### TODO
- Backtest with real data. I think this will require mocking the prices returned from the SwapRouter.
- Run the fuzzer across time with real backtest data.
- Maybe increase percentage precision to 18 decimals to completely capture all WAVAX precision?
- Actually make use of the stored prices in the InvestmentManager. Currently they're stored but not used.
- Currently I make the assumption that an asset -> USDT pair exists, but this may not always be true. Need to use liquidation path to WAVAX to get to USDT, or just store a specific USDT liquidation path.
- !InvestmentManager: It should have a switch on an asset where it's in watch-only mode: The price history can be collected from week to week but it can't be bought
- CashManager: Only liquidate when a cash asset is entirely removed? Getting a new asset up to desired % is only done through new investments.
- What happens when a particular liquidation or purchase fails repeatedly? It would prevent it from moving to the next item. This could be solved by removing it from the list even if it fails. But would need to prevent a malicious user from always removing it from the list.
- Important test: Run some tests on the redemptions stepping on the investment liquidations. Start a redemption that queues some liquidations. Then start an investment buy that queues some liquidations.
- Test a multi-token swap path. Currently I'm only testing token A->B paths, but what if it's A->B->C?
- Important test: Test a situation where a liquidation or purchase is greater than a 1% priceImpact. Do this by making it a very large amount of WAVAX in the fund. Should be able to eventually achieve the desired outcomes by making one purchase per day
- Focus on the "pull over push" model listed [here](https://eth.wiki/en/howto/smart-contract-safety) and consider changing some of your CashManager's push external calls to pull calls where a user has to call it for each one rather than the contract calling it in a for loop
- !Test: What happens when a CashManager.setCashAllocations doesn't fully liquidate a cash asset because it would have too much of a price impact? It will be stuck in the contract. I need to allow the rest of it to be liquidated through subsequent liquidation calls
- Test: How does the kelly bet sizing work with many assets in the investment manager, all of them qualifying for purchases?
- !Rather than an ERC20, make the token an ANT and wrap it as an ARC-20. See [here](https://medium.com/avalancheavax/apricot-phase-five-p-c-atomic-transfers-atomic-transaction-batching-and-c-chain-fee-algorithm-912507489ecd) and [here](https://docs.avax.network/build/references/coreth-arc20s). This will allow the token to be used on the X, P, and other chains.
- Test: Someone externally sending to the contract one of the cash or investment assets, thereby throwing the percentages off balance.
- Test: Someone sends AVAX to MaldenFeuersteinERC20. It should be sent to the CashManager on the next call to invest()
- Test: When the kelly bet is larger than the total cash on hand, liquidate all cash assets to WAVAX and use all WAVAX to buy
- Find a way to test same-block transactions in the Fuzzing tests using [this](https://hardhat.org/hardhat-network/explanation/mining-modes.html).
- Test: Redemption scenario where there is nothing in the cash manager, everything is in the investment manager
- FIXME: There's an issue with redemptions where users can get a bit more than they are owed because the swap slippage in the liquidations performed to get their WAVAX are not taken into account for the amount of WAVAX given to the user.
- FIXME: The 24hr wait on investing and redeeming can be easily circumvented by sending the MALD to a different address
- FIXME: The fuzzer frequently hits a situation where a stale buy determination isn't removed
- FIXME: Sending MALD 1:1 for AVAX only makes sense during an initial investment period. After that it will need to be according to the value of what's already in the fund. Otherwise there's the potential to dilute the earlier investors.
- Make sure all swaps are limited in how frequently they can be done. An attack vector to erode value needlessly would be to perform swaps over and over, incurring slippage and liquidity provider fees.
- Test: There is nothing in the CashManager because everything has been invested. The fuzzer sometimes covers this case.
- Test: Make the userInvestmentAmount a random number from 1 to 100 in all of the tests

### TODO Frontend
- Show the cash manager holdings on the website
- Show the investment manager holdings on the website
- Ensure that the MetaMask choice of chain is correct - want Avalanche, not Ethereum
- Show a graph on the website "This is what your assets would've done had they been left alone in a fund such as this over the past 2 years".

### Main Net Launch TODO
- Make sure you get your events right, they're currently under-defined and under-called
- Should I deploy the ERC20 token onto the X-Chain?
- Ensure that investment pausing and total stop work
- Make sure these are upgradeable: parameters such as the 1% difference, how often the cash balances can be updated, the seconds per block number
- Make sure you can change the contracts' choice of DEX used to route swaps
- Remove all console.log in Solidity
- Can I prevent tokens from getting stuck in the contract? See [here](https://soliditydeveloper.com/eip-165)
- Use Gnosis Safe with 2 out of 4 keys required for the owner of the contract. This is to help prevent hacks like the [bzx hack](https://bzx.network/blog/prelminary-post-mortem) where a single key stolen ruined the entire project. Keep the keys on separate hardware wallets and never use them on the same machine.
- Turn up the compiler optimization runs to 2000
- Go through this checklist: https://docs.openzeppelin.com/learn/preparing-for-mainnet
- Make sure all functions have the right ownership (public vs onlyOwner vs initializer)
- Make sure you call the initializer of all parent contracts
- Make sure there are two mitigations against flash attacks: Speed bump on getting a price and using a price for a swap, as well as a check that a swap is only a certain portion of the DEX's reserves.

### Future Directions
- Idea: I'm essentially building an on-chain DEX aggregator. Would others want to use such a service?
- Break up large orders into smaller orders over time
- Should be able to stake its assets for rewards
- Cross-chain support with Ethereum and Solana. I want to be able to purchase assets on Ethereum.

### Update Packages
- `yarn add solidity-coverage --save-dev`
- `npm update`
- `npm outdated`
- `npm install package@latest` this will update the version listed in package.json

### Remember
- Any time you divide by a uint that's representing a number with decimals, you need to find multiply the numerator by (10 ** number of decimals of the denominator)
- Always remember to change state variables before making calls to external contracts
- Always do multiplication before division to preserve precision
- Never set class variables within loops, only local variables. Setting a `storage` variable in a loop incurs a costly SSTORE on every set
- A lot of solidity security issues seem to revolve around being able to do things repeatedly in a loop. This characterizes both re-entrancy attacks and many of the . Introduce speed bumps to prevent this.
- Remember to be very precise with your `>`, `<`, `<=`, `>=`, `==` comparisons. This caused [the Compound hack](https://twitter.com/Mudit__Gupta/status/1443454935639609345?s=20)
- I attempted and will stay away from using an address router to centrally store addresses that are called by other contracts because the function calls consume a huge amount of 24kb size limit in the compiled contracts.

### Resources
- Reduce contract size: https://soliditydeveloper.com/max-contract-size
- Optimize gas usage: https://mudit.blog/solidity-gas-optimization-tips/
- [Solidity Security Considerations](https://docs.soliditylang.org/en/v0.8.10/security-considerations.html)
- [Smart Contract Security](https://eth.wiki/en/howto/smart-contract-safety)
- [Known attacks](https://consensys.github.io/smart-contract-best-practices/known_attacks/)
- [The State of Smart Contract Upgrades](https://blog.openzeppelin.com/the-state-of-smart-contract-upgrades/) is a good read. Prefer UUPS upgradeability as described [here](https://docs.openzeppelin.com/contracts/4.x/api/proxy#transparent-vs-uups)
