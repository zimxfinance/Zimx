
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ZIMX Token
 * @author Munashe 'Emperor Roy' Mupoto / Blackmass Enterprises Ltd
 * @notice Stable reserve-backed token designed for ZimX Finance ecosystem aligned with Zimbabwe Vision 2030.
 */
contract ZIMXToken is ERC20, Ownable {
    /**
     * @dev Constructor mints initial supply to initial owner.
     * @param initialOwner Address to receive initial supply and ownership.
     * @param initialSupply Initial total supply minted to owner.
     */
    constructor(address initialOwner, uint256 initialSupply) ERC20("ZIMX Token", "ZIMX") Ownable(initialOwner) {
        _mint(initialOwner, initialSupply);
    }
}
