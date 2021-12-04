//SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "hardhat/console.sol"; // TODO: Remove this for production

// local
import "contracts/IWAVAX.sol";
import "contracts/ICashManager.sol";
import "contracts/IValueHelpers.sol";
import "contracts/IInvestmentManager.sol";
import "contracts/Library.sol";
import "contracts/IMaldenFeuersteinERC20.sol";

// Typical Redemption Usage:
// user.approve() - approve the contract to take from the user the malden ERC20 tokens
// requestRedeem()
// CashManager.prepareDryPowderForRedemption()
// CashManager.processLiquidation() in a loop until liquidations are complete
// redeem() to finally exchange the ERC20 token for the equivalent value in WAVAX

contract MaldenFeuersteinERC20 is ERC20Upgradeable,
                                  ERC165Upgradeable,
                                  OwnableUpgradeable,
                                  UUPSUpgradeable,
                                  PausableUpgradeable,
                                  IMaldenFeuersteinERC20 {
    event Redeemed(uint256); // Emitted when a user successfully redeems, with the amount of redeemed
    struct Redemption {
        uint256 maldenCoinAmount;
        uint256 wavaxAmount;
    }

    address wavaxAddress;
    IWAVAX wavax;
    ICashManager cashManager;
    IValueHelpers valueHelpers;
    IInvestmentManager investmentManager;

    string private constant TOKEN_NAME = "Malden Feuerstein";
    string private constant TOKEN_SYMBOL = "MALD";
    uint256 private constant TOTAL_SUPPLY = 1e5 ether; // TODO: How many shares did Berkshire Hathaway have originally?
    uint256 public circulatingSupply;
    bool private stopped; // emergency stop everything
    bool private investmentPeriodOver; // Set to true once the initial investment period is over
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
        investmentPeriodOver = false;
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
  
    function endInvestmentPeriod() external onlyOwner {
        investmentPeriodOver = true;
    }
  
    // The caller should receive tokens in exchange for putting in money
    // Anyone can call this
    function invest() payable external whenNotPaused {
        require(!stopped, "Can not invest during emergency stop.");
        // Do nothing if all of the investment tokens have been depleted
        require(!investmentPeriodOver, "Can not invest after invest period has ended.");
        require(balanceOf(address(this)) > 0, "The contract must have MALD to give for investment.");
        require(balanceOf(address(this)) >= msg.value, "The investment is too large.");
        timestamps[msg.sender] = block.timestamp;
        // Based on https://ethereum.stackexchange.com/questions/65660/accepting-ether-in-a-smart-contract/65661
        investmentBalances[msg.sender] = msg.value;
        uint256 avaxBalance = address(this).balance;
        circulatingSupply += avaxBalance;
        require(circulatingSupply <= TOTAL_SUPPLY, "Cannot have more MALD tokens than TOTAL_SUPPLY");
        if (balanceOf(address(this)) <= 0) {
            investmentPeriodOver = true;
        }
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
        uint256 wavaxAmount = authorizedRedemptions[msg.sender].wavaxAmount;
        require(maldenCoinAmount > 0, "Not authorized to redeem anything.");
        require(wavaxAmount > 0, "Not authorized to redeem anything.");
        authorizedRedemptions[msg.sender].maldenCoinAmount = 0; // no longer authorized
        authorizedRedemptions[msg.sender].wavaxAmount = 0;
        circulatingSupply -= maldenCoinAmount;
        require(circulatingSupply <= TOTAL_SUPPLY, "Cannot have more MALD tokens than TOTAL_SUPPLY");
        // take the tokens from the person
        require(wavax.balanceOf(address(cashManager)) >= wavaxAmount,
                "CashManager doesn't have enough WAVAX to fill this redemption.");
        emit Redeemed(wavaxAmount);
        bool success = this.transferFrom(msg.sender, address(this), maldenCoinAmount);
        require(success, "transferFrom failed.");
        success = wavax.transferFrom(address(cashManager), address(this), wavaxAmount);
        require(success, "transferFrom failed.");
        // convert it from WAVAX to AVAX
        wavax.withdraw(wavaxAmount);
        // send it to the user
        payable(msg.sender).transfer(wavaxAmount);
    }

    function getAuthorizedRedemptionAmounts(address user) external view returns (uint256, uint256) { // anyone can call this
        return (authorizedRedemptions[user].maldenCoinAmount, authorizedRedemptions[user].wavaxAmount);
    }
  
    // Redeems the tokens in this contract for the equivalent value of underlying assets
    // This needs to be callable when paused so that users can redeem their tokens
    function requestRedeem(uint256 amount) external { // Anyone can call this
        require(!stopped, "Can not redeem during emergency stop.");
        require(amount <= balanceOf(msg.sender), "Must own at least as many tokens as attempting to redeem.");
        require(authorizedRedemptions[msg.sender].wavaxAmount == 0, "Redemption already in progress.");
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
        uint256 totalValueInWAVAX = valueHelpers.cashManagerTotalValueInWAVAX() + investmentManager.totalValueInWAVAX();
        // What percent of the total number of ERC20 tokens is amount?
        uint256 redemptionPercentage = Library.valueIsWhatPercentOf(amount, circulatingSupply);
        uint256 wavaxAmountToRedeem = Library.percentageOf(totalValueInWAVAX, redemptionPercentage);
        require(wavaxAmountToRedeem > 0, "Cannot redeem 0 WAVAX.");
        authorizedRedemptions[msg.sender] = Redemption(amount, wavaxAmountToRedeem);
    }
}
