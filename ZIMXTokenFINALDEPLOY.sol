// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title ZIMXTokenFINALDEPLOY
 * @notice ZIMX utility token with fixed supply, governance gating and telemetry for allocations.
 */
contract ZIMXTokenFINALDEPLOY is ERC20, ERC20Burnable, Pausable, ERC20Permit {
    /// @notice Address responsible for protocol governance (intended multisig).
    address public governance;
    /// @notice Address holding the treasury allocation minted at deployment.
    address public treasury;
    /// @notice Indicates whether the treasury destination can no longer be updated.
    bool public treasurySealed;

    /// @notice Emitted when governance control is transferred.
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    /// @notice Emitted when the treasury wallet is updated.
    event TreasuryUpdated(address indexed newTreasury);
    /// @notice Emitted when the treasury wallet becomes immutable.
    event TreasurySealed();
    /// @notice Emitted when an allocation is recorded and distributed.
    event AllocationSet(string indexed name, uint256 amount, address indexed destination);

    modifier onlyGovernance() {
        require(msg.sender == governance, "NOT_GOVERNANCE");
        _;
    }

    /**
     * @notice Deploys the ZIMX token, assigns governance and mints the full supply to the treasury wallet.
     * @param governance_ Address of the governance multisig.
     * @param treasury_ Address of the treasury wallet that receives the initial supply.
     */
    constructor(address governance_, address treasury_)
        ERC20("ZIMX Token", "ZIMX")
        ERC20Permit("ZIMX Token")
    {
        require(governance_ != address(0), "GOV_ZERO");
        require(treasury_ != address(0), "TREASURY_ZERO");
        governance = governance_;
        treasury = treasury_;

        uint256 supply = 1_000_000_000 * 10 ** decimals();
        _mint(treasury_, supply);
    }

    /**
     * @notice Returns token decimals (ZIMX uses 6 decimals).
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Helper alias returning the total supply of tokens.
     */
    function totalSupplyRaw() external view returns (uint256) {
        return totalSupply();
    }

    /**
     * @notice Transfers governance rights to a new address.
     * @param newGovernance Address of the new governance multisig.
     */
    function transferGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "GOV_ZERO");
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    /**
     * @notice Updates the treasury wallet. Disabled after sealing.
     * @param newTreasury Address of the new treasury wallet.
     */
    function updateTreasury(address newTreasury) external onlyGovernance {
        require(!treasurySealed, "TREASURY_SEALED");
        require(newTreasury != address(0), "TREASURY_ZERO");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Permanently disables future treasury updates.
     */
    function sealTreasury() external onlyGovernance {
        require(!treasurySealed, "TREASURY_SEALED");
        treasurySealed = true;
        emit TreasurySealed();
    }

    /**
     * @notice Distributes tokens from the treasury wallet and records the allocation telemetry.
     * @param destination Recipient of the tokens.
     * @param amount Amount of tokens to transfer (6 decimals).
     * @param allocationName Human-readable allocation label.
     */
    function distributeFromTreasury(address destination, uint256 amount, string calldata allocationName)
        external
        onlyGovernance
    {
        require(destination != address(0), "DEST_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        _transfer(treasury, destination, amount);
        emit AllocationSet(allocationName, amount, destination);
    }

    /**
     * @notice Pauses all token transfers.
     */
    function pause() external onlyGovernance {
        _pause();
    }

    /**
     * @notice Unpauses token transfers.
     */
    function unpause() external onlyGovernance {
        _unpause();
    }

    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }
}
