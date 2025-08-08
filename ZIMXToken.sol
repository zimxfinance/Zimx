// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// @title ZIMXToken
/// @notice ERC20 token with phased minting, vesting integration and treasury management.
/// @dev Uses SafeMath for explicit arithmetic operations.

contract ZIMXToken is ERC20, Ownable {
    using SafeMath for uint256;
    /// @notice Structure defining a minting phase.
    /// @param name Human-readable name of the phase.
    /// @param cap Maximum tokens that can be minted in this phase.
    /// @param minted Tokens already minted in this phase.
    /// @param locked Whether further minting in this phase is locked.
    struct Phase {
        string name;
        uint256 cap;
        uint256 minted;
        bool locked;
    }

    Phase[] public phases;
    uint256 public currentPhase;

    address public treasuryWallet;
    address public vestingContract;
    uint256 public immutable maxSupply;

    /// @notice Emitted when a new phase is created.
    /// @param name Name of the phase.
    /// @param cap Cap of the phase in raw token units.
    event PhaseCreated(string name, uint256 cap);
    /// @notice Emitted when a phase is locked.
    /// @param phaseIndex Index of the phase that was locked.
    event PhaseLocked(uint256 phaseIndex);
    /// @notice Emitted when the treasury wallet is updated.
    /// @param newWallet Address of the new treasury wallet.
    event TreasuryWalletUpdated(address newWallet);
    /// @notice Emitted when the vesting contract is updated.
    /// @param newVesting Address of the new vesting contract.
    event VestingContractUpdated(address newVesting);
    /// @notice Emitted when tokens are minted.
    /// @param to Recipient of the minted tokens.
    /// @param amount Amount of tokens minted.
    /// @param phaseIndex Phase during which the tokens were minted.
    event TokensMinted(address indexed to, uint256 amount, uint256 phaseIndex);
    /// @notice Emitted when tokens are burned.
    /// @param from Address initiating the burn.
    /// @param amount Amount of tokens burned.
    event TokensBurned(address indexed from, uint256 amount);
    /// @notice Emitted when tokens are locked in the vesting contract.
    /// @param beneficiary Address receiving the vested tokens.
    /// @param amount Amount of tokens locked.
    /// @param releaseTime Timestamp when the tokens will be releasable.
    event TokensLocked(address indexed beneficiary, uint256 amount, uint256 releaseTime);
    /// @notice Emitted when the current phase is updated.
    /// @param newPhase Index of the new current phase.
    event CurrentPhaseUpdated(uint256 newPhase);

    /// @notice Interface for the vesting contract.
    interface IVesting {
        function lockTokens(address beneficiary, uint256 amount, uint256 releaseTime) external;
    }

    /// @notice Deploys the token contract.
    /// @param initialOwner Owner of the contract and initial token recipient.
    /// @param initialTreasuryWallet Address of the treasury wallet.
    /// @param initialSupply Tokens to mint on deployment (raw units).
    /// @param maxSupply_ Maximum total supply cap of the token.
    constructor(
        address initialOwner,
        address initialTreasuryWallet,
        uint256 initialSupply,
        uint256 maxSupply_
    ) ERC20("ZIMX Token", "ZIMX") Ownable(initialOwner) {
        require(maxSupply_ > 0, "Max supply zero");
        require(initialSupply <= maxSupply_, "Initial > max");
        treasuryWallet = initialTreasuryWallet;
        maxSupply = maxSupply_;
        _mint(initialOwner, initialSupply);
    }

    /// @notice Returns the number of decimals used for representation.
    /// @return Number of decimals for token units.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Creates a new minting phase.
    /// @dev Phase name cannot be empty and cap must be greater than zero.
    /// @param name Human-readable name for the phase.
    /// @param cap Maximum tokens (raw units) mintable in this phase.
    function createPhase(string calldata name, uint256 cap) external onlyOwner {
        require(bytes(name).length > 0, "Empty name");
        require(cap > 0, "Cap zero");
        phases.push(Phase(name, cap, 0, false));
        emit PhaseCreated(name, cap);
    }

    /// @notice Locks a phase preventing further minting.
    /// @param index Index of the phase to lock.
    function lockPhase(uint256 index) external onlyOwner {
        require(index < phases.length, "Invalid phase index");
        phases[index].locked = true;
        emit PhaseLocked(index);
    }

    /// @notice Mints tokens during the current phase.
    /// @dev Amount is specified in raw units including decimals and must be greater than zero.
    /// @param to Recipient of the tokens.
    /// @param amount Number of tokens to mint in raw units.
    function mint(address to, uint256 amount) external onlyOwner {
        require(amount > 0, "Amount zero");
        require(currentPhase < phases.length, "Phase not set");
        Phase storage phase = phases[currentPhase];
        require(!phase.locked, "Current phase locked");
        require(phase.minted.add(amount) <= phase.cap, "Cap exceeded");
        require(totalSupply().add(amount) <= maxSupply, "Max supply exceeded");

        phase.minted = phase.minted.add(amount);
        _mint(to, amount);
        emit TokensMinted(to, amount, currentPhase);
    }

    /// @notice Burns tokens from the caller's balance.
    /// @param amount Number of tokens to burn in raw units.
    function burn(uint256 amount) external {
        require(amount > 0, "Amount zero");
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }

    /// @notice Sets the current phase for minting.
    /// @param index Index of the phase to activate.
    function setCurrentPhase(uint256 index) external onlyOwner {
        require(index < phases.length, "Invalid phase index");
        currentPhase = index;
        emit CurrentPhaseUpdated(index);
    }

    /// @notice Updates the treasury wallet address.
    /// @param newWallet Address of the new treasury wallet.
    function updateTreasuryWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Zero address");
        treasuryWallet = newWallet;
        emit TreasuryWalletUpdated(newWallet);
    }

    /// @notice Updates the vesting contract address.
    /// @param newVesting Address of the new vesting contract.
    function setVestingContract(address newVesting) external onlyOwner {
        vestingContract = newVesting;
        emit VestingContractUpdated(newVesting);
    }

    /// @notice Locks tokens via the vesting contract.
    /// @dev Transfers tokens to the vesting contract and invokes its lock function.
    /// @param beneficiary Address to receive the vested tokens.
    /// @param amount Number of tokens to lock (raw units including decimals).
    /// @param releaseTime Timestamp at which the tokens can be released.
    function lockTokens(address beneficiary, uint256 amount, uint256 releaseTime) external onlyOwner {
        require(vestingContract != address(0), "Vesting not set");
        require(beneficiary != address(0), "Zero beneficiary");
        require(amount > 0, "Amount zero");
        require(releaseTime > block.timestamp, "Invalid release");

        _transfer(msg.sender, vestingContract, amount);
        IVesting(vestingContract).lockTokens(beneficiary, amount, releaseTime);
        emit TokensLocked(beneficiary, amount, releaseTime);
    }
}
