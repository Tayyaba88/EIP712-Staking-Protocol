// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  StakingContract - Staking & Locking with EIP-712 Signatures
 * @author Tayyaba Sabir
 * @notice This smart contract enables token staking, time-locked staking tiers, 
 *         and reward distribution. It also supports off-chain EIP-712 signature 
 *         verification for the purpose of restriction interaction through our own protocol.
 *
 * @custom:version 1.0
 *
 * ---------------------------------------------------------------------------
 * Open-source example for educational and demonstration purposes.
 * Maintained by: Tayyaba Sabir
 * GitHub: https://github.com/Tayyaba88
 * ---------------------------------------------------------------------------
 */

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface INewXToken {
    function mint(address to, uint256 amount) external;
}

interface IVault {
    function deposit(address user, uint256 amount) external;
}

contract Staking is Initializable, EIP712Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {

    IERC20 public StakeAddress;
    INewXToken public RewardAddress;
    address public vault;

    address constant burnAddress = 0x000000000000000000000000000000000000dEaD;
    uint256 constant STAKE_POOL_LIMIT = 45000000 * 1e18;
    uint256 constant LOCK_POOL_LIMIT = 10000000000 * 1e18;

    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        uint256 endTime;
        bool claimed;
    }

    bytes32 private constant STAKE_TYPEHASH = keccak256(
        "Stake(address user,address stakedToken,uint256 amount,uint256 interval,bytes32 id,bytes32 status,bytes32 salt,uint256 expiry)"
    );

    bytes32 private constant LOCK_TYPEHASH = keccak256(
        "Lock(address user,address stakedToken,uint256 amount,uint256 rewards,bytes32 id,bytes32 salt,uint256 expiry)"
    );

    bytes32 private constant CLAIM_TYPEHASH = keccak256(
        "Claim(address user,address stakedToken,uint256 interval,uint256 stakeId,uint256 rewards,bytes32 id,bytes32 salt,uint256 expiry)"
    );

    mapping(address => mapping(uint256 => mapping(uint256 => Stake))) public stakes;
    mapping(address => mapping(uint256 => uint256)) public stakeCounts;
    mapping(uint256 => bool) public tiers;
    mapping(address => uint256) public  userStakes;

    /**
     * @notice Mapping of signer addresses approved to sign off-chain messages
     */
    mapping(address => bool) public isSigner;

    /**
     * @notice Mapping of used salts to prevent replay attacks in signature verification
     */
    mapping(bytes32 => bool) public usedSalts;

    uint256 public totalLocked;
    uint256 public totalStaked;

    error InvalidZeroAddress();
    error InvalidInput();
    error SaltAlreadyUsed();
    error BalanceTooLow();
    error InvalidSigner();
    error SignatureExpired();
    error NotClaimable();
    error NotMatured();
    error InvalidTier();
    error PoolLimitExceeded();
    error AlreadyClaimed();

  
    event Unstaked(address indexed user, uint256 interval, uint256 stakeId, uint256 amount);
    event TierAdded(uint256 indexed interval, bool status);
    event Staked(address indexed user, uint256 interval, uint256 stakeId, uint256 amount, uint256 startTime, uint256 endTime);
    event RewardsClaimed(address indexed user, uint256 interval, uint256 stakeId, uint256 rewards);
    event Locked(address indexed user, uint256 amount, uint256 rewards, bytes32 id, bytes32 salt);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @dev Can only be called once.
     * @param _Reward Address
     * @param _Stake Address
     */
    function initialize(address _Reward, address _Stake,  address _vault) public initializer {
        if (_Reward == address(0) || _Stake == address(0)) revert InvalidZeroAddress();

        __EIP712_init("Staking", "1");
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        RewardAddress = INewXToken(_Reward);
        StakeAddress = IERC20(_Stake);
        vault = _vault;

    }

    function lockTokens(bytes calldata _encodedData, bytes memory _signature ) external nonReentrant {
        (uint256 amount, uint256 rewards, bytes32 id, bytes32 salt, uint256 expiry) =
        abi.decode(_encodedData, (uint256, uint256, bytes32, bytes32, uint256));

        if (amount == 0 || id == bytes32(0) || salt == bytes32(0) || rewards == 0 || expiry == 0) revert InvalidInput();
        if (usedSalts[salt]) revert SaltAlreadyUsed();
        if (StakeAddress.balanceOf(msg.sender) < amount) revert BalanceTooLow();
        if (totalLocked + amount > LOCK_POOL_LIMIT ) revert PoolLimitExceeded();

        usedSalts[salt] = true;

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            LOCK_TYPEHASH,
            msg.sender,
            StakeAddress,
            amount,
            rewards,
            id,
            salt,
            expiry
        )));

        address signer = ECDSA.recover(digest, _signature);

        if (!isSigner[signer]) revert InvalidSigner();
        if (block.timestamp > expiry) revert SignatureExpired();

        totalLocked += amount;

        require(StakeAddress.transferFrom(msg.sender, burnAddress, amount), "burn transfer failed");

        IVault(vault).deposit(msg.sender, rewards);
        RewardAddress.mint(vault, rewards);

        emit Locked(msg.sender, amount, rewards, id, salt);
    }

    function stakeTokens(bytes calldata _encodedData, bytes memory _signature) external nonReentrant {
        (uint256 amount, uint256 interval, bytes32 id, bytes32 status, bytes32 salt, uint256 expiry) =
        abi.decode(_encodedData, (uint256, uint256, bytes32, bytes32, bytes32, uint256));

        if (amount == 0 || id == bytes32(0) || status == bytes32(0) || salt == bytes32(0) || interval == 0 || expiry == 0) revert InvalidInput();
        if (usedSalts[salt]) revert SaltAlreadyUsed();
        if (!tiers[interval]) revert InvalidTier();
        if (StakeAddress.balanceOf(msg.sender) < amount) revert BalanceTooLow();
        if (totalStaked + amount > STAKE_POOL_LIMIT ) revert PoolLimitExceeded();

        usedSalts[salt] = true;

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            STAKE_TYPEHASH,
            msg.sender,
            StakeAddress,
            amount,
            interval,
            id,
            status,
            salt,
            expiry
        )));

        address signer = ECDSA.recover(digest, _signature);
        if (!isSigner[signer]) revert InvalidSigner();
        if (block.timestamp > expiry) revert SignatureExpired();

        uint256 selectedDuration = interval * 30 days;
        uint256 endDuartion = block.timestamp + selectedDuration;

        totalStaked += amount;
        userStakes[msg.sender] += amount;

        uint256 stakeId = stakeCounts[msg.sender][interval]++;
        stakes[msg.sender][interval][stakeId] = Stake({
            amount: amount,                 // Amount Staked 
            startTime: block.timestamp,       // Time of staking
            duration: selectedDuration,       // duration
            endTime: endDuartion,             
            claimed: false                    // Initially unclaimed
        });

        StakeAddress.transferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, interval, stakeId, amount, block.timestamp, endDuartion);
    }

    function claimRewards(bytes calldata _encodedData, bytes memory _signature) external nonReentrant {
        (uint256 interval, uint256 stakeId, uint256 rewards, bytes32 id, bytes32 salt, uint256 expiry) =
        abi.decode(_encodedData, (uint256, uint256, uint256, bytes32, bytes32, uint256));

        if (interval == 0 || id == bytes32(0) || salt == bytes32(0) || rewards == 0 || expiry == 0) revert InvalidInput();
        if (!tiers[interval]) revert InvalidTier();
        if (usedSalts[salt]) revert SaltAlreadyUsed();

        usedSalts[salt] = true;

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            CLAIM_TYPEHASH,
            msg.sender,
            StakeAddress,
            interval,
            stakeId,
            rewards,
            id,
            salt,
            expiry
        )));

        address signer = ECDSA.recover(digest, _signature);

        if (!isSigner[signer]) revert InvalidSigner();
        if (block.timestamp > expiry) revert SignatureExpired();

        Stake storage userStake = stakes[msg.sender][interval][stakeId];
        if (userStake.amount == 0) revert InvalidInput();
        if (block.timestamp < userStake.endTime) revert NotClaimable();
        if (userStake.claimed) revert AlreadyClaimed();

        userStake.claimed = true;
        totalStaked -= userStake.amount;
        userStakes[msg.sender] -= userStake.amount;

        uint256 rewardAfterFee = (rewards * 9800) / 10000; //BPS 

        IVault(vault).deposit(msg.sender, rewardAfterFee);
        RewardAddress.mint(vault, rewards);
        require(StakeAddress.transfer(msg.sender, userStake.amount), "staketoken transfer failed");

        emit RewardsClaimed(msg.sender, interval, stakeId, rewards);
    }

    /// @notice Allows owner to withdraw staked tokens from contract
    function withdrawStakedToken(address to, uint256 amount) external onlyOwner nonReentrant{
        require(to != address(0), "Invalid recipient");
        uint256 balance = StakeAddress.balanceOf(address(this));
        require(amount <= balance, "Insufficient balance");
        StakeAddress.transfer(to, amount);
    }

    function addTier(
       uint256 lockDuration
    ) external onlyOwner {
        if (lockDuration == 0) revert InvalidInput();

        tiers[lockDuration] = true;

        emit TierAdded(lockDuration, true);
    }

    function updateTierStatus(
       uint256 lockDuration,
       bool status
    ) external onlyOwner {
        if (lockDuration == 0) revert InvalidInput();
        if (tiers[lockDuration] == status) revert InvalidInput();

        tiers[lockDuration] = status;

        emit TierAdded(lockDuration, status);
    }

    /**
     * @notice Adds a backend signer. Only callable by the contract owner.
     * @param _signer Address of the signer to be added.
     */
    function addSigner(address _signer) external onlyOwner {
        if (_signer == address(0)) revert InvalidInput();

        isSigner[_signer] = true;
    }

    /**
     * @notice Removes a backend signer. Only callable by the contract owner.
     * @param _signer Address of the signer to be removed.
     */
    function removeSigner(address _signer) external onlyOwner {
        if (_signer == address(0)) revert InvalidInput();
        if (!isSigner[_signer]) revert InvalidInput();

        isSigner[_signer] = false;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        require(newImplementation != address(0), "invalid address");
    }
}