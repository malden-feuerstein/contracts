//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "hardhat/console.sol"; // TODO: Remove this for production
import "@openzeppelin/contracts/utils/math/Math.sol"; // min()

// local
import "contracts/interfaces/IWAVAX.sol";
import "contracts/interfaces/ICashManager.sol";
import "contracts/interfaces/IValueHelpers.sol";
import "contracts/interfaces/IInvestmentManager.sol";
import "contracts/Library.sol";
import "contracts/interfaces/IMaldenFeuersteinERC20.sol";

// Typical Redemption Usage:
// requestRedeem()
// CashManager.prepareDryPowderForRedemption()
// CashManager.processLiquidation() in a loop until liquidations are complete
// InvestmentManager.prepareDryPowderForRedemption()
// InvestmentManager.processLiquidation() in a loop until liquidations are complete
// approve() - the user approves the contract to take from the user the malden ERC20 tokens
// redeem() to finally exchange the ERC20 token for the equivalent value in WAVAX

contract MaldenFeuersteinERC20 is ERC20Upgradeable,
                                  ERC165Upgradeable,
                                  OwnableUpgradeable,
                                  UUPSUpgradeable,
                                  PausableUpgradeable,
                                  IMaldenFeuersteinERC20 {
    // Emitted when a user successfully redeems
    // Amount of AVAX redeemed, Amount of MALD exchanged for it
    event Redeemed(uint256, uint256);
    event Invested(uint256);
    struct Redemption {
        uint256 maldenCoinAmount;
        uint256 cashManagerWAVAXAmount;
        uint256 investmentManagerWAVAXAmount;
    }
    // constants
    string private constant TOKEN_NAME = "Malden Feuerstein";
    string private constant TOKEN_SYMBOL = "MALD";
    uint256 private constant TOTAL_SUPPLY = 1e5 ether;
    uint256 private constant TESTING_HARD_LIMIT = 100 ether;

    // contracts
    address wavaxAddress;
    IWAVAX wavax;
    ICashManager cashManager;
    IValueHelpers valueHelpers;
    IInvestmentManager investmentManager;

    // storage
    uint256 public circulatingSupply;
    bool private stopped; // emergency stop everything
    // https://samczsun.com/so-you-want-to-use-a-price-oracle/
    mapping(address => uint256) private timestamps;
    mapping(address => uint256) private investmentBalances; // These are the balances of AVAX invested by investors
    mapping(address => Redemption) private authorizedRedemptions;

    function initialize() external virtual initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ERC20_init(TOKEN_NAME, TOKEN_SYMBOL);
        __ERC165_init();
        __Pausable_init();
          // msg.sender
          // The ERC20 contract starts with all of the tokens
        _mint(address(this), TOTAL_SUPPLY);
        stopped = false;
        circulatingSupply = 0;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setAddresses(address localWAVAXAddress,
                          address cashManagerAddress,
                          address valueHelpersAddress,
                          address investmentManagerAddress) external onlyOwner whenNotPaused {
        require(localWAVAXAddress != address(0));
        wavaxAddress = localWAVAXAddress;
        wavax = IWAVAX(localWAVAXAddress);
        cashManager = ICashManager(cashManagerAddress);
        valueHelpers = IValueHelpers(valueHelpersAddress);
        investmentManager = IInvestmentManager(investmentManagerAddress);
    }
  
    // This stops all activity: investments, allocations, and redemptions
    // This would be an emergency situation
    // It's not expected this will be used but it's conceivable an emergency could occur such as bad information from an orcale
    // that would break the redemptions for a temporary period of time. During such a time it would be intelligent to stop
    // everything including redemptions, and then re-open once the oracle has been fixed.
    function stop() external onlyOwner whenNotPaused {
        _pause();
        stopped = true;
    }
  
    function unstop() external onlyOwner whenPaused {
        _unpause();
        stopped = false;
    }

    function pause() external whenNotPaused onlyOwner {
        _pause();
    }

    function unpause() external whenPaused onlyOwner {
        _unpause();
    }
  
    // The caller should receive tokens in exchange for putting in money
    // Anyone can call this
    function invest() payable external whenNotPaused {
        require(!stopped, "Can not invest during emergency stop.");
        // Do nothing if all of the investment tokens have been depleted
        require(balanceOf(address(this)) > 0, "The contract must have MALD to give for investment.");
        require(balanceOf(address(this)) >= msg.value, "The investment is too large.");
        timestamps[msg.sender] = block.timestamp;
        // Based on https://ethereum.stackexchange.com/questions/65660/accepting-ether-in-a-smart-contract/65661
        investmentBalances[msg.sender] = msg.value;
        emit Invested(msg.value);
        uint256 avaxBalance = msg.value;
        circulatingSupply += avaxBalance;
        require(circulatingSupply <= TOTAL_SUPPLY, "Cannot have more MALD tokens than TOTAL_SUPPLY");
        require(circulatingSupply <= TESTING_HARD_LIMIT, "Testing phase hard limit reached.");
        // FIXME: Should this be 1:1?
        bool success = this.transfer(msg.sender, msg.value); // transfer from this contract to the investor
        require(success, "transfer failed.");
        wavax.deposit{value: avaxBalance}();
        success = wavax.transfer(address(cashManager), avaxBalance);
        require(success, "wavax transfer to CashManager failed.");
    }

    // This must be defined to enable withdrawing WAVAX to AVAX in this contract
    // https://docs.soliditylang.org/en/v0.8.6/contracts.html?highlight=receive#receive-ether-function
    receive() external payable {
    }

    // Call this after sufficient WAVAX liquidity has been achieved in the CashManager
    // This needs to be callable when the contract is paused so that users can redeem their tokens
    function redeem() external {
        require(!stopped, "Can not redeem during emergency stop.");
        uint256 maldenCoinAmount = authorizedRedemptions[msg.sender].maldenCoinAmount;
        uint256 cashManagerWAVAXAmount = authorizedRedemptions[msg.sender].cashManagerWAVAXAmount;
        uint256 investmentManagerWAVAXAmount = authorizedRedemptions[msg.sender].investmentManagerWAVAXAmount;
        require(maldenCoinAmount > 0, "Not authorized to redeem anything.");
        require(cashManagerWAVAXAmount + investmentManagerWAVAXAmount > 0, "Not authorized to redeem anything.");
        authorizedRedemptions[msg.sender].maldenCoinAmount = 0; // no longer authorized
        authorizedRedemptions[msg.sender].cashManagerWAVAXAmount = 0;
        authorizedRedemptions[msg.sender].investmentManagerWAVAXAmount = 0;
        uint256 oldCirculatingSupply = circulatingSupply;
        circulatingSupply -= maldenCoinAmount;
        require(circulatingSupply <= TOTAL_SUPPLY, "Cannot have more MALD tokens than TOTAL_SUPPLY");

        cashManagerWAVAXAmount = Math.min(cashManagerWAVAXAmount, wavax.balanceOf(address(cashManager)));
        investmentManagerWAVAXAmount = Math.min(investmentManagerWAVAXAmount, wavax.balanceOf(address(investmentManager)));
        // Confirm again that the amount being taken out is the right percentage
        uint256 maldPercentageOfFund = Library.valueIsWhatPercentOf(maldenCoinAmount, oldCirculatingSupply);
        require(maldPercentageOfFund <= Library.ONE_HUNDRED_PERCENT);
        uint256 totalValueInWAVAX = valueHelpers.cashManagerTotalValueInWAVAX() + valueHelpers.investmentManagerTotalValueInWAVAX();
        uint256 wavaxPercentageOfFund = Library.valueIsWhatPercentOf(cashManagerWAVAXAmount + investmentManagerWAVAXAmount,
                                                                     totalValueInWAVAX);
        if (wavaxPercentageOfFund > maldPercentageOfFund) { // Must be within 0.1%
            require(wavaxPercentageOfFund - maldPercentageOfFund < 1e5, "Coin: Percentage too large.");
            console.log("wavaxPercentageOfFund = %s, maldPercentageOfFund = %s", wavaxPercentageOfFund, maldPercentageOfFund);
        } else {
            console.log("maldPercentageOfFund = %s, wavaxPercentageOfFund = %s", maldPercentageOfFund, wavaxPercentageOfFund);
            require(maldPercentageOfFund - wavaxPercentageOfFund < 1e5, "Coin: Percentage too small.");
        }
        // take the tokens from the person
        uint256 wavaxTotal = cashManagerWAVAXAmount + investmentManagerWAVAXAmount;
        emit Redeemed(wavaxTotal, maldenCoinAmount);
        bool success = this.transferFrom(msg.sender, address(this), maldenCoinAmount);
        require(success, "transferFrom failed.");
        success = wavax.transferFrom(address(cashManager), address(this), cashManagerWAVAXAmount);
        require(success, "transferFrom failed.");
        success = wavax.transferFrom(address(investmentManager), address(this), investmentManagerWAVAXAmount);
        require(success, "transferFrom failed.");
        // convert it from WAVAX to AVAX
        wavax.withdraw(wavaxTotal);
        // send it to the user
        payable(msg.sender).transfer(wavaxTotal);
    }

    function getAuthorizedRedemptionAmounts(address user) external view returns (uint256, uint256, uint256) { // anyone can call this
        return (authorizedRedemptions[user].maldenCoinAmount,
                authorizedRedemptions[user].cashManagerWAVAXAmount,
                authorizedRedemptions[user].investmentManagerWAVAXAmount);
    }
  
    // Redeems the tokens in this contract for the equivalent value of underlying assets
    // This needs to be callable when paused so that users can redeem their tokens
    function requestRedeem(uint256 amount) external { // Anyone can call this
        require(!stopped, "Can not redeem during emergency stop.");
        require(amount <= balanceOf(msg.sender), "Must own at least as many tokens as attempting to redeem.");
        require(authorizedRedemptions[msg.sender].cashManagerWAVAXAmount == 0, "Redemption already in progress.");
        require(authorizedRedemptions[msg.sender].investmentManagerWAVAXAmount == 0, "Redemption already in progress.");
        require(authorizedRedemptions[msg.sender].maldenCoinAmount == 0, "Redemption already in progress.");
        // Should not be able to invest() and redeem() in the same transaction, but non-investors can redeem even during the
        // investment period
        if (investmentBalances[msg.sender] > 0) {
            // require vs assert: https://ethereum.stackexchange.com/questions/15166/difference-between-require-and-assert-and-the-difference-between-revert-and-thro
            assert(block.timestamp > timestamps[msg.sender]);
            // speed bump
            // FIXME: This can be sidestepped simply by sending the tokens to another address
            require((block.timestamp - timestamps[msg.sender]) >= 86400, "Must wait at least one day to redeem an investment.");
        }
        require(amount > 0, "Cannot redeem 0 tokens");
        uint256 cashManagerValueInWAVAX = valueHelpers.cashManagerTotalValueInWAVAX();
        uint256 totalValueInWAVAX = cashManagerValueInWAVAX + valueHelpers.investmentManagerTotalValueInWAVAX();
        // What percent of the total number of ERC20 tokens is amount?
        uint256 redemptionPercentage = Library.valueIsWhatPercentOf(amount, circulatingSupply);
        uint256 wavaxAmountToRedeem = Library.percentageOf(totalValueInWAVAX, redemptionPercentage);
        require(wavaxAmountToRedeem > 0, "Cannot redeem 0 WAVAX.");
        if (wavaxAmountToRedeem > cashManagerValueInWAVAX) { // Need to do InvestmentManager liquidations too
            authorizedRedemptions[msg.sender] = Redemption(amount,
                                                           cashManagerValueInWAVAX,
                                                           wavaxAmountToRedeem - cashManagerValueInWAVAX);
        } else {
            authorizedRedemptions[msg.sender] = Redemption(amount, wavaxAmountToRedeem, 0);
        }
    }
}
