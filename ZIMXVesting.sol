// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title ZIMXVesting
 * @notice Linear vesting contract for team allocations governed by a multisig.
 */
contract ZIMXVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Timestamp when governance managed operations become available (2027-01-01 UTC).
    uint256 public constant GOVERNANCE_ENABLE_TS = 1_798_761_600;

    /// @notice Token being vested.
    IERC20 public immutable token;
    /// @notice Global vesting start timestamp.
    uint64 public immutable start;
    /// @notice Duration of the cliff in seconds after the start timestamp.
    uint64 public immutable cliffDuration;
    /// @notice Total vesting duration in seconds.
    uint64 public immutable duration;
    /// @notice Indicates whether the schedules can be revoked.
    bool public immutable revocable;

    /// @notice Governance address controlling schedule creation and management.
    address public governance;
    /// @notice Address nominated to assume governance pending explicit acceptance.
    address public pendingGovernance;
    /// @notice Aggregate amount of tokens still locked across all schedules.
    uint256 public totalLocked;

    struct StoredSchedule {
        uint256 totalAmount;
        uint256 released;
        bool revoked;
    }

    /// @notice Mapping of beneficiary address to their vesting schedule.
    mapping(address => StoredSchedule) public schedules;

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

    OnChainPromise[] private _promises;

    /// @notice Emitted when governance transfer is initiated.
    event GovernanceTransferStarted(address indexed currentGovernance, address indexed pendingGovernance);
    /// @notice Emitted when a pending governance transfer is cancelled.
    event GovernanceTransferCancelled(address indexed cancelledGovernance);
    /// @notice Emitted when governance is transferred.
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    /// @notice Emitted when new vesting schedules are created.
    event VestingScheduleCreated(address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration);
    /// @notice Emitted when vested tokens are released to a beneficiary.
    event TokensReleased(address indexed beneficiary, uint256 amount);
    /// @notice Emitted when a vesting schedule is revoked.
    event VestingRevoked(address indexed beneficiary, uint256 refundedAmount);
    /// @notice Emitted when tokens are transferred into the vesting contract.
    event TeamVestingFunded(uint256 totalAmount);
    /// @notice Emitted when the vesting contract is funded with contextual metadata.
    event VestingFunded(uint256 totalAmount, uint256 timestamp);
    /// @notice Emitted when an on-chain promise is recorded.
    event OnChainPromiseRecorded(uint256 indexed promiseId, string details);
    /// @notice Emitted when a promise status is updated.
    event OnChainPromiseStatusUpdated(uint256 indexed promiseId, PromiseStatus status);
    /// @notice Emitted when a beneficiary is added to the vesting schedules.
    event BeneficiaryAdded(
        address indexed beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bool revocable
    );
    /// @notice Emitted when a vesting schedule is revoked.
    event BeneficiaryRevoked(address indexed beneficiary, uint256 refunded, uint256 vestedPaidOut);
    /// @notice Emitted when a beneficiary claims vested tokens.
    event Claimed(address indexed beneficiary, uint256 amount, uint256 timestamp);
    /// @notice Emitted when vesting schedule parameters are updated.
    event ScheduleUpdated(address indexed beneficiary, uint64 start, uint64 cliff, uint64 duration);

    struct VestingSchedule {
        uint256 total;
        uint256 claimed;
        uint64 start;
        uint64 cliff;
        uint64 duration;
        bool revocable;
        bool revoked;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "NOT_GOVERNANCE");
        _;
    }

    modifier after2027() {
        require(block.timestamp >= GOVERNANCE_ENABLE_TS, "GOV_LOCKED_UNTIL_2027");
        _;
    }

    /**
     * @param token_ Address of the ZIMX token being vested.
     * @param governance_ Governance multisig address.
     * @param start_ Vesting start timestamp.
     * @param cliffDuration_ Duration of the cliff from the start timestamp.
     * @param duration_ Total vesting duration.
     * @param revocable_ Whether schedules created by this contract are revocable.
     */
    constructor(
        IERC20 token_,
        address governance_,
        uint64 start_,
        uint64 cliffDuration_,
        uint64 duration_,
        bool revocable_
    ) {
        require(address(token_) != address(0), "TOKEN_ZERO");
        require(governance_ != address(0), "GOV_ZERO");
        require(duration_ > 0, "DURATION_ZERO");
        require(duration_ >= cliffDuration_, "CLIFF_GT_DURATION");

        token = token_;
        governance = governance_;
        start = start_;
        cliffDuration = cliffDuration_;
        duration = duration_;
        revocable = revocable_;
    }

    /**
     * @notice Transfers governance rights to a new address.
     * @param newGovernance Address of the new governance multisig.
     */
    function transferGovernance(address newGovernance) external onlyGovernance after2027 {
        require(newGovernance != address(0), "GOV_ZERO");
        require(newGovernance != governance, "ALREADY_GOV");
        require(pendingGovernance == address(0), "PENDING_GOV");
        pendingGovernance = newGovernance;
        emit GovernanceTransferStarted(governance, newGovernance);
    }

    /**
     * @notice Cancels a pending governance transfer.
     */
    function cancelGovernanceTransfer() external onlyGovernance after2027 {
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
     * @notice Funds the vesting contract with tokens from a designated source.
     * @param from Address supplying the tokens (must approve this contract).
     * @param amount Amount of tokens to transfer.
     */
    function fund(address from, uint256 amount) external onlyGovernance nonReentrant {
        require(from != address(0), "FROM_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        token.safeTransferFrom(from, address(this), amount);
        emit TeamVestingFunded(amount);
        emit VestingFunded(amount, block.timestamp);
    }

    /**
     * @notice Batch-creates vesting schedules for the provided beneficiaries.
     * @param beneficiaries Addresses receiving vesting schedules.
     * @param amounts Token amounts for each beneficiary.
     */
    function batchCreateSchedules(address[] calldata beneficiaries, uint256[] calldata amounts) external onlyGovernance {
        require(beneficiaries.length == amounts.length, "LENGTH_MISMATCH");
        require(beneficiaries.length > 0, "EMPTY_ARRAY");

        for (uint256 i = 0; i < beneficiaries.length; i++) {
            address beneficiary = beneficiaries[i];
            uint256 amount = amounts[i];
            require(beneficiary != address(0), "BENEFICIARY_ZERO");
            require(amount > 0, "AMOUNT_ZERO");

            StoredSchedule storage schedule = schedules[beneficiary];
            require(schedule.totalAmount == 0 && schedule.released == 0, "SCHEDULE_EXISTS");

            schedule.totalAmount = amount;
            schedule.released = 0;
            schedule.revoked = false;
            totalLocked += amount;

            emit VestingScheduleCreated(beneficiary, amount, start, cliffDuration, duration);
            emit BeneficiaryAdded(beneficiary, amount, start, start + cliffDuration, duration, revocable);
            emit ScheduleUpdated(beneficiary, start, start + cliffDuration, duration);
        }

        require(token.balanceOf(address(this)) >= totalLocked, "INSUFFICIENT_FUNDS");
    }

    /**
     * @notice Calculates the amount of vested tokens that can be released for a beneficiary.
     * @param beneficiary Address of the beneficiary.
     * @return Amount of tokens currently releasable.
     */
    function releasable(address beneficiary) public view returns (uint256) {
        return _releasableAmount(schedules[beneficiary]);
    }

    /**
     * @notice Returns the vesting schedule metadata for a beneficiary.
     * @param beneficiary Address of the beneficiary to query.
     */
    function getSchedule(address beneficiary) external view returns (VestingSchedule memory) {
        StoredSchedule storage schedule = schedules[beneficiary];
        return
            VestingSchedule({
                total: schedule.totalAmount,
                claimed: schedule.released,
                start: start,
                cliff: start + cliffDuration,
                duration: duration,
                revocable: revocable,
                revoked: schedule.revoked
            });
    }

    /**
     * @notice Releases vested tokens for the caller.
     */
    function release() external nonReentrant {
        StoredSchedule storage schedule = schedules[msg.sender];
        uint256 amount = _releasableAmount(schedule);
        require(amount > 0, "NOTHING_TO_RELEASE");
        schedule.released += amount;
        require(totalLocked >= amount, "LOCKED_UNDERFLOW");
        totalLocked -= amount;
        token.safeTransfer(msg.sender, amount);
        emit TokensReleased(msg.sender, amount);
        emit Claimed(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Revokes a vesting schedule when revocable vesting is enabled.
     * @param beneficiary Address whose schedule should be revoked.
     */
    function revoke(address beneficiary) external onlyGovernance nonReentrant {
        require(revocable, "NOT_REVOCABLE");
        StoredSchedule storage schedule = schedules[beneficiary];
        require(schedule.totalAmount > 0, "NO_SCHEDULE");
        require(!schedule.revoked, "ALREADY_REVOKED");

        uint256 vestedAmount = _vestedAmount(schedule);
        uint256 releasableAmount = vestedAmount > schedule.released ? vestedAmount - schedule.released : 0;
        uint256 refund = schedule.totalAmount - vestedAmount;

        uint256 unreleased = schedule.totalAmount - schedule.released;
        require(totalLocked >= unreleased, "LOCKED_UNDERFLOW");
        totalLocked -= unreleased;

        schedule.revoked = true;
        uint256 previouslyReleased = schedule.released;
        schedule.totalAmount = vestedAmount;
        schedule.released = vestedAmount;

        if (releasableAmount > 0) {
            token.safeTransfer(beneficiary, releasableAmount);
            emit TokensReleased(beneficiary, releasableAmount);
        }
        if (refund > 0) {
            token.safeTransfer(governance, refund);
        }

        emit VestingRevoked(beneficiary, refund);
        emit BeneficiaryRevoked(beneficiary, refund, previouslyReleased + releasableAmount);
        emit ScheduleUpdated(beneficiary, start, start + cliffDuration, duration);
    }

    /**
     * @notice Records a new on-chain promise for the vesting program.
     * @param details Description of the commitment made.
     * @return promiseId Identifier of the stored promise.
     */
    function recordOnChainPromise(string calldata details)
        external
        onlyGovernance
        after2027
        returns (uint256 promiseId)
    {
        require(bytes(details).length > 0, "PROMISE_EMPTY");
        promiseId = _promises.length;
        _promises.push(OnChainPromise({details: details, timestamp: uint64(block.timestamp), status: PromiseStatus.Pending}));
        emit OnChainPromiseRecorded(promiseId, details);
    }

    /**
     * @notice Updates the status of a recorded promise.
     * @param promiseId Identifier of the promise to update.
     * @param status New status value.
     */
    function updateOnChainPromiseStatus(uint256 promiseId, PromiseStatus status) external onlyGovernance after2027 {
        require(promiseId < _promises.length, "PROMISE_OOB");
        OnChainPromise storage promise = _promises[promiseId];
        require(promise.status != status, "STATUS_UNCHANGED");
        promise.status = status;
        promise.timestamp = uint64(block.timestamp);
        emit OnChainPromiseStatusUpdated(promiseId, status);
    }

    /**
     * @notice Returns information about a stored promise.
     * @param promiseId Identifier of the promise.
     * @return details Promise description.
     * @return timestamp Timestamp of the most recent update.
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
     * @notice Returns the number of promises recorded on-chain.
     */
    function onChainPromiseCount() external view returns (uint256) {
        return _promises.length;
    }

    function _vestedAmount(StoredSchedule memory schedule) internal view returns (uint256) {
        if (block.timestamp < start + cliffDuration) {
            return 0;
        }
        uint256 elapsed = block.timestamp > start ? block.timestamp - start : 0;
        if (elapsed >= duration) {
            return schedule.totalAmount;
        }
        return (schedule.totalAmount * elapsed) / duration;
    }

    function _releasableAmount(StoredSchedule storage schedule) internal view returns (uint256) {
        if (schedule.totalAmount == 0 || schedule.revoked) {
            return 0;
        }
        if (block.timestamp < start + cliffDuration) {
            return 0;
        }
        uint256 elapsed = block.timestamp > start ? block.timestamp - start : 0;
        if (elapsed >= duration) {
            return schedule.totalAmount - schedule.released;
        }
        uint256 vested = (schedule.totalAmount * elapsed) / duration;
        return vested - schedule.released;
    }
}
