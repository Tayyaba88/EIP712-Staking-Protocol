// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  RewardVault - User Reward Vault for RewardToken
 * @author Tayyaba Sabir
 * @notice This contract securely holds and manages staking reward tokens for users
 *         participating in the Custom Staking Protocol. It tracks balances, enforces
 *         withdrawal rules, and ensures controlled reward distribution.
 *
 * @custom:version 1.0
 *
 * ---------------------------------------------------------------------------
 * Open-source example for educational and demonstration purposes.
 * Maintained by: Tayyaba Sabir
 * GitHub: https://github.com/Tayyaba88
 * ---------------------------------------------------------------------------
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Rewardvault is Initializable, OwnableUpgradeable {
    IERC20 public rewardToken;
    address public stakingContract;

    mapping(address => uint256) public balances;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, address indexed to, uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event StakingContractUpdated(address indexed stakingContract);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _rewardToken) public initializer {
        __Ownable_init(msg.sender);
        rewardToken = IERC20(_rewardToken);
    }

    function setStakingContract(address _stakingContract) external onlyOwner {
        require(_stakingContract != address(0), "Invalid contract");
        stakingContract = _stakingContract;
        emit StakingContractUpdated(_stakingContract);
    }

    /**
     * @notice Called by staking contract to log earned tokens for a user.
     * @param user Address to credit rewards to.
     * @param amount Amount of tokens earned.
     */
    function deposit(address user, uint256 amount) external {
        require(msg.sender == stakingContract, "Not authorized");
        require(user != address(0), "Invalid user");
        balances[user] += amount;
        emit Deposited(user, amount);
    }

    /**
     * @notice Allows user to withdraw their earned tokens to a specified (whitelisted) address.
     * @dev GReward token enforces whitelist checks in its internal `_update()` logic.
     * @param to The recipient address for the withdrawal (must be whitelisted in Reward token).
     */
    function withdraw(address to, uint256 _amount) external {
        require(to != address(0), "Invalid recipient");

        uint256 amount = balances[msg.sender];
        require(amount > 0, "Nothing to withdraw");
        require(_amount > 0 && _amount <= amount, "Insufficient Balance");

        balances[msg.sender] = amount - _amount;

        require(rewardToken.transfer(to, _amount), "Transfer failed");

        emit Withdrawn(msg.sender, to, _amount);
    }

    /**
     * @notice Emergency token recovery by owner.
     */
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        require(rewardToken.transfer(to, amount), "Emergency transfer failed");
        emit EmergencyWithdraw(to, amount);
    }
}
