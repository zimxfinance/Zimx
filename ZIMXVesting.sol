// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ZIMXVesting
 * @notice Linear vesting contract for team allocations governed by a multisig.
 */
contract ZIMXVesting {
    using SafeERC20 for IERC20;

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
    /// @notice Aggregate amount of tokens still locked across all schedules.
    uint256 public totalLocked;

    struct VestingSchedule {
        uint256 totalAmount;
        uint256 released;
        bool revoked;
    }

    /// @notice Mapping of beneficiary address to their vesting schedule.
    mapping(address => VestingSchedule) public schedules;

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

    modifier onlyGovernance() {
        require(msg.sender == governance, "NOT_GOVERNANCE");
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
    function transferGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "GOV_ZERO");
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    /**
     * @notice Funds the vesting contract with tokens from a designated source.
     * @param from Address supplying the tokens (must approve this contract).
     * @param amount Amount of tokens to transfer.
     */
    function fund(address from, uint256 amount) external onlyGovernance {
        require(from != address(0), "FROM_ZERO");
        require(amount > 0, "AMOUNT_ZERO");
        token.safeTransferFrom(from, address(this), amount);
        emit TeamVestingFunded(amount);
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

            VestingSchedule storage schedule = schedules[beneficiary];
            require(schedule.totalAmount == 0 && schedule.released == 0, "SCHEDULE_EXISTS");

            schedule.totalAmount = amount;
            schedule.released = 0;
            schedule.revoked = false;
            totalLocked += amount;

            emit VestingScheduleCreated(beneficiary, amount, start, cliffDuration, duration);
        }

        require(token.balanceOf(address(this)) >= totalLocked, "INSUFFICIENT_FUNDS");
    }

    /**
     * @notice Calculates the amount of vested tokens that can be released for a beneficiary.
     * @param beneficiary Address of the beneficiary.
     * @return Amount of tokens currently releasable.
     */
    function releasable(address beneficiary) public view returns (uint256) {
        VestingSchedule memory schedule = schedules[beneficiary];
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

    /**
     * @notice Releases vested tokens for the caller.
     */
    function release() external {
        uint256 amount = releasable(msg.sender);
        require(amount > 0, "NOTHING_TO_RELEASE");
        VestingSchedule storage schedule = schedules[msg.sender];
        schedule.released += amount;
        require(totalLocked >= amount, "LOCKED_UNDERFLOW");
        totalLocked -= amount;
        token.safeTransfer(msg.sender, amount);
        emit TokensReleased(msg.sender, amount);
    }

    /**
     * @notice Revokes a vesting schedule when revocable vesting is enabled.
     * @param beneficiary Address whose schedule should be revoked.
     */
    function revoke(address beneficiary) external onlyGovernance {
        require(revocable, "NOT_REVOCABLE");
        VestingSchedule storage schedule = schedules[beneficiary];
        require(schedule.totalAmount > 0, "NO_SCHEDULE");
        require(!schedule.revoked, "ALREADY_REVOKED");

        uint256 vestedAmount = _vestedAmount(schedule);
        uint256 releasableAmount = vestedAmount > schedule.released ? vestedAmount - schedule.released : 0;
        uint256 refund = schedule.totalAmount - vestedAmount;

        uint256 unreleased = schedule.totalAmount - schedule.released;
        require(totalLocked >= unreleased, "LOCKED_UNDERFLOW");
        totalLocked -= unreleased;

        schedule.revoked = true;
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
    }

    function _vestedAmount(VestingSchedule memory schedule) internal view returns (uint256) {
        if (block.timestamp < start + cliffDuration) {
            return 0;
        }
        uint256 elapsed = block.timestamp > start ? block.timestamp - start : 0;
        if (elapsed >= duration) {
            return schedule.totalAmount;
        }
        return (schedule.totalAmount * elapsed) / duration;
    }
}
