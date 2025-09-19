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
    /// @notice Address nominated to assume governance pending acceptance.
    address public pendingGovernance;
    /// @notice Indicates whether the treasury destination can no longer be updated.
    bool public treasurySealed;

    /// @notice Emitted when governance control is transferred.
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    /// @notice Emitted when governance transfer is initiated and must be accepted.
    event GovernanceTransferStarted(address indexed currentGovernance, address indexed pendingGovernance);
    /// @notice Emitted when a pending governance transfer is cancelled.
    event GovernanceTransferCancelled(address indexed cancelledGovernance);
    /// @notice Emitted when the treasury wallet is updated.
    event TreasuryUpdated(address indexed newTreasury);
    /// @notice Emitted when the treasury wallet becomes immutable.
    event TreasurySealed();
    /// @notice Emitted when an allocation is recorded and distributed.
    event AllocationSet(string indexed name, uint256 amount, address indexed destination);
    enum PromiseStatus {
        Pending,
        Kept,
        Broken
    }

    struct OnChainPromise {
        string details;
        uint64 timestamp;
        PromiseStatus status;
    }

    /// @notice Emitted when a new on-chain promise is recorded.
    event OnChainPromiseRecorded(uint256 indexed promiseId, string details);
    /// @notice Emitted when the status of a promise changes.
    event OnChainPromiseStatusUpdated(uint256 indexed promiseId, PromiseStatus status);

    OnChainPromise[] private _promises;

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
        _initiateGovernanceTransfer(newGovernance);
    }

    /**
     * @notice Initiates governance transfer using the ownership naming convention for compatibility.
     * @param newOwner Address of the contract set to receive governance powers.
     */
    function transferOwnership(address newOwner) external onlyGovernance {
        _initiateGovernanceTransfer(newOwner);
    }

    /**
     * @notice Cancels a pending governance transfer.
     */
    function cancelGovernanceTransfer() external onlyGovernance {
        address pending = pendingGovernance;
        require(pending != address(0), "NO_PENDING_GOV");
        pendingGovernance = address(0);
        emit GovernanceTransferCancelled(pending);
    }

    /**
     * @notice Accepts a pending governance transfer.
     */
    function acceptGovernance() external {
        address pending = pendingGovernance;
        require(pending != address(0), "NO_PENDING_GOV");
        require(msg.sender == pending, "NOT_PENDING_GOV");
        pendingGovernance = address(0);
        emit GovernanceTransferred(governance, pending);
        governance = pending;
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

    /**
     * @notice Records a new on-chain promise for community transparency.
     * @param details Human-readable description of the promise.
     * @return promiseId Identifier of the stored promise.
     */
    function recordOnChainPromise(string calldata details) external onlyGovernance returns (uint256 promiseId) {
        require(bytes(details).length > 0, "PROMISE_EMPTY");
        promiseId = _promises.length;
        _promises.push(OnChainPromise({details: details, timestamp: uint64(block.timestamp), status: PromiseStatus.Pending}));
        emit OnChainPromiseRecorded(promiseId, details);
    }

    /**
     * @notice Updates the status of a recorded promise.
     * @param promiseId Identifier of the promise to update.
     * @param status New status value for the promise.
     */
    function updateOnChainPromiseStatus(uint256 promiseId, PromiseStatus status) external onlyGovernance {
        require(promiseId < _promises.length, "PROMISE_OOB");
        OnChainPromise storage promise = _promises[promiseId];
        require(promise.status != status, "STATUS_UNCHANGED");
        promise.status = status;
        promise.timestamp = uint64(block.timestamp);
        emit OnChainPromiseStatusUpdated(promiseId, status);
    }

    /**
     * @notice Returns information about a stored on-chain promise.
     * @param promiseId Identifier of the promise to retrieve.
     * @return details Promise description.
     * @return timestamp Timestamp of the most recent status update.
     * @return status Current status of the promise.
     */
    function getOnChainPromise(uint256 promiseId)
        external
        view
        returns (string memory details, uint64 timestamp, PromiseStatus status)
    {
        require(promiseId < _promises.length, "PROMISE_OOB");
        OnChainPromise storage promise = _promises[promiseId];
        return (promise.details, promise.timestamp, promise.status);
    }

    /**
     * @notice Returns the total number of promises recorded on-chain.
     */
    function onChainPromiseCount() external view returns (uint256) {
        return _promises.length;
    }

    function _initiateGovernanceTransfer(address newGovernance) internal {
        require(newGovernance != address(0), "GOV_ZERO");
        require(newGovernance.code.length > 0, "OWNER_NOT_CONTRACT");
        require(newGovernance != governance, "ALREADY_GOV");
        require(pendingGovernance == address(0), "PENDING_GOV");
        pendingGovernance = newGovernance;
        emit GovernanceTransferStarted(governance, newGovernance);
    }
}
