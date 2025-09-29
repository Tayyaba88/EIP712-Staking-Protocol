// SPDX-License-Identifier: Apache 2
pragma solidity ^0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title  RewardToken
 * @author Tayyaba Sabir
 * @notice A demonstration ERC20 token used within the Custom Staking Protocol for rewards.
 *
 * @custom:version 1.0
 *
 * ---------------------------------------------------------------------------
 * Open-source example for educational and demonstration purposes.
 * Maintained by: Tayyaba Sabir
 * GitHub: https://github.com/<Tayyaba88>
 * ---------------------------------------------------------------------------
 */

contract RewardToken is Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, ERC20PausableUpgradeable, OwnableUpgradeable, UUPSUpgradeable{

    uint256 public constant MAX_SUPPLY = 10_000_000_000e18;
    uint256 private constant BPS_DENOMINATOR = 10000;
    uint256 private constant BPS_PERCENTAGE = 200; // 2%

    address public minter;
    address public treasury;

    mapping(address => bool) public isWhitelisted;

    event NewMinter(address newMinter);
    event NewLp(address newLp);
    event NewTreasury(address newTreasury);

    error CallerNotMinter(address caller);
    error InvalidZeroAddress();
    error NotWhitelisted();

    /**
     * @dev Storage gap for future upgrades
     * @custom:oz-upgrades-unsafe-allow state-variable-immutable
     * state-variable-assignment 
     */ 
    uint256[50] private __gap;

    /**
     * @dev Modifier to restrict functions to only the minter
     */
    modifier onlyMinter() {
        if (msg.sender != minter) {
            revert CallerNotMinter(msg.sender);
        }
        _;
    }
   
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @dev Can only be called once.
     * @param _name Name of the token
     * @param _symbol Symbol of the token
     * @param _minter Address assigned as the minter
     */
    function initialize(string memory _name, string memory _symbol, address _minter) public initializer {
        if (_minter == address(0)) revert InvalidZeroAddress();

        __ERC20_init(_name, _symbol);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();  // Initialize UUPSUpgradeable

        minter = _minter;
    }

    /**
     * @notice Mints tokens to a given address
     * @dev Only callable by the minter and when not paused
     * @param _account Address to receive minted tokens
     * @param _amount Amount of tokens to mint
     */
    function mint(address _account, uint256 _amount) external onlyMinter whenNotPaused 
    {
        require(totalSupply() + _amount <= MAX_SUPPLY, "Mint exceeds MAX_SUPPLY");
        _mint(_account, _amount);
    }

    /**
     * @notice Ensures that token transfers and burns are only executed when the contract is not paused.
     * @dev Overrides the base _update function to enforce the `whenNotPaused` modifier. Enforce the tax deduction on each tarnsfer and mint.
     * @param from The sender address, to, the recipient address, and value, the amount being transferred or burned.
     */
    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
        whenNotPaused
    {
        // If burn operation: skip tax (to == address(0))
        if (to == address(0)) {
            if (!isWhitelisted[from]) revert NotWhitelisted();
            super._update(from, to, value);
            return;
        }

        // Apply 2% tax (on minting and transfers)
        uint256 taxAmount = (value * BPS_PERCENTAGE) / BPS_DENOMINATOR;
        uint256 finalAmount = value - taxAmount;


        // If minting (from == address(0)), burn and liquidity will come from `to`
        if (from == address(0)) {
            if (!isWhitelisted[to]) revert NotWhitelisted();

            // Mint full amount first
            super._update(from, to, value);

            // Now the recipient has full amount,deduct tax
            super._update(to, treasury, taxAmount);
            return;
        }

        if (!isWhitelisted[from] || !isWhitelisted[to]) revert NotWhitelisted();
            // Regular transfer case (apply tax from sender)
            super._update(from, treasury, taxAmount);
            super._update(from, to, finalAmount);
    }
    
    /**
     * @notice Updates the minter address
     * @dev Only callable by the owner
     * @param newMinter New address to be assigned as minter
     */
    function setMinter(address newMinter) external onlyOwner {
        if (newMinter == address(0)) {
            revert InvalidZeroAddress();
        }
        minter = newMinter;
        emit NewMinter(newMinter);
    }

    function setWhitelistBatch(address[] calldata users, bool status) external onlyOwner whenNotPaused {
        for (uint i = 0; i < users.length; i++) {
            isWhitelisted[users[i]] = status;
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
    * @notice Sets the treasury address
    * @dev Only callable by the owner
    * @param _address New address to be assigned as Treasury
    */
    function setTreasuryAddress(address _address) external onlyOwner {
        if (_address == address(0)) {
            revert InvalidZeroAddress();
        }
        treasury = _address;
        emit NewTreasury(_address);
    }

    /**
     * @dev Required function for UUPSUpgradeable to restrict upgraded to only owner.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        require(newImplementation != address(0), "Invalid address");
    }
}