// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ZIMXToken
 * @notice ZIMX utility token with fixed supply and emergency pause.
 */
contract ZIMXToken is ERC20, ERC20Burnable, Pausable, ERC20Permit, Ownable {
    /// @notice Address receiving the initial token supply and holding treasury funds.
    address public treasury;

    /// @notice Emitted when the treasury wallet is updated.
    event TreasuryUpdated(address indexed newTreasury);

    /**
     * @notice Deploys the ZIMX token, assigns the initial owner, and mints the full supply to the treasury.
     * @dev Initializes {ERC20Permit} for EIP-2612 support.
     * @param initialOwner Address that will be granted ownership of the contract.
     * @param treasury_ Address of the treasury wallet that receives the full token supply.
     */
    constructor(address initialOwner, address treasury_)
        ERC20("ZIMX Token", "ZIMX")
        ERC20Permit("ZIMX Token")
        Ownable(initialOwner)
    {
        require(initialOwner != address(0), "Owner address is zero");
        require(treasury_ != address(0), "Treasury address is zero");
        require(initialOwner != treasury_, "Owner and treasury cannot be the same");
        treasury = treasury_;
        uint256 supply = 1_000_000_000 * 10 ** decimals();
        _mint(treasury_, supply);
    }

    /**
     * @notice Returns token decimals.
     * @dev ZIMX uses 6 decimals to align with ecosystem standards.
     * @return The number of decimals used by the token.
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Returns the total supply of tokens.
     * @dev Helper alias for {totalSupply}.
     */
    function totalSupplyRaw() external view returns (uint256) {
        return totalSupply();
    }

    /**
     * @notice Updates the treasury wallet.
     * @dev Only callable by the contract owner.
     * @param newTreasury Address of the new treasury wallet.
     * Emits a {TreasuryUpdated} event.
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Treasury address is zero");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Pauses all token transfers.
     * @dev Only callable by the contract owner. Emits a {Paused} event.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses token transfers.
     * @dev Only callable by the contract owner. Emits an {Unpaused} event.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20)
        whenNotPaused
    {
        super._update(from, to, value);
    }

}
