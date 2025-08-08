// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ZIMXToken is ERC20, Ownable {
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

    event PhaseCreated(string name, uint256 cap);
    event PhaseLocked(uint256 phaseIndex);
    event TreasuryWalletUpdated(address newWallet);
    event VestingContractUpdated(address newVesting);

    constructor(
        address initialOwner,
        address initialTreasuryWallet,
        uint256 initialSupply
    ) ERC20("ZIMX Token", "ZIMX") Ownable(initialOwner) {
        treasuryWallet = initialTreasuryWallet;
        _mint(initialOwner, initialSupply);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function createPhase(string calldata name, uint256 cap) external onlyOwner {
        phases.push(Phase(name, cap, 0, false));
        emit PhaseCreated(name, cap);
    }

    function lockPhase(uint256 index) external onlyOwner {
        require(index < phases.length, "Invalid phase index");
        phases[index].locked = true;
        emit PhaseLocked(index);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        require(phases.length > 0, "No phases created");
        Phase storage phase = phases[currentPhase];
        require(!phase.locked, "Current phase locked");
        require(phase.minted + amount <= phase.cap, "Cap exceeded");

        phase.minted += amount;
        _mint(to, amount);
    }

    function setCurrentPhase(uint256 index) external onlyOwner {
        require(index < phases.length, "Invalid phase index");
        currentPhase = index;
    }

    function updateTreasuryWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Zero address");
        treasuryWallet = newWallet;
        emit TreasuryWalletUpdated(newWallet);
    }

    function setVestingContract(address newVesting) external onlyOwner {
        vestingContract = newVesting;
        emit VestingContractUpdated(newVesting);
    }
}
