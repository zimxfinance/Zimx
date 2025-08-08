// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ZIMXVesting
 * @notice Simple vesting contract allowing linear release of tokens after a cliff.
 */
contract ZIMXVesting is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Token being vested.
    IERC20 public immutable token;

    struct VestingSchedule {
        uint256 totalAmount; // total tokens to be vested
        uint64 start;        // start time of the vesting schedule
        uint64 cliff;        // duration in seconds of the cliff after start
        uint64 duration;     // total vesting duration in seconds
        uint256 released;    // amount of tokens already released
    }

    /// @notice Mapping of beneficiary address to their vesting schedule.
    mapping(address => VestingSchedule) public schedules;

    /// @notice Emitted when a new vesting schedule is created.
    event VestingScheduleCreated(address indexed beneficiary, uint256 amount, uint64 start, uint64 cliff, uint64 duration);
    /// @notice Emitted when vested tokens are released to a beneficiary.
    event TokensReleased(address indexed beneficiary, uint256 amount);

    /**
     * @param token_ Address of the ZIMX token being vested.
     * @param owner_ Address that will own the vesting contract (treasury multisig).
     */
    constructor(IERC20 token_, address owner_) Ownable(owner_) {
        token = token_;
    }

    /**
     * @notice Sets a vesting schedule for a beneficiary and transfers tokens to the contract.
     * @param beneficiary Address receiving the vested tokens.
     * @param amount Total amount of tokens to vest.
     * @param start Start timestamp for the vesting schedule.
     * @param cliffDuration Duration of the cliff in seconds after start.
     * @param vestingDuration Total vesting duration in seconds.
     */
    function setVestingSchedule(
        address beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliffDuration,
        uint64 vestingDuration
    ) external onlyOwner {
        require(beneficiary != address(0), "Zero beneficiary");
        require(vestingDuration > 0, "Duration zero");
        require(vestingDuration >= cliffDuration, "Cliff > duration");
        require(schedules[beneficiary].totalAmount == 0, "Schedule exists");

        schedules[beneficiary] = VestingSchedule({
            totalAmount: amount,
            start: start,
            cliff: cliffDuration,
            duration: vestingDuration,
            released: 0
        });

        token.safeTransferFrom(owner(), address(this), amount);
        emit VestingScheduleCreated(beneficiary, amount, start, cliffDuration, vestingDuration);
    }

    /**
     * @notice Calculates the amount of vested tokens that can be released for a beneficiary.
     * @param beneficiary Address of the beneficiary.
     * @return Amount of tokens currently releasable.
     */
    function releasable(address beneficiary) public view returns (uint256) {
        VestingSchedule memory schedule = schedules[beneficiary];
        if (schedule.totalAmount == 0) {
            return 0;
        }
        if (block.timestamp < schedule.start + schedule.cliff) {
            return 0;
        }
        uint256 elapsed = block.timestamp - schedule.start;
        if (elapsed >= schedule.duration) {
            return schedule.totalAmount - schedule.released;
        }
        uint256 vested = (schedule.totalAmount * elapsed) / schedule.duration;
        return vested - schedule.released;
    }

    /**
     * @notice Releases vested tokens for the caller.
     */
    function release() external {
        uint256 amount = releasable(msg.sender);
        require(amount > 0, "Nothing to release");
        schedules[msg.sender].released += amount;
        token.safeTransfer(msg.sender, amount);
        emit TokensReleased(msg.sender, amount);
    }
}
