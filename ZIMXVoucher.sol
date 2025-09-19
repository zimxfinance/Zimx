// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title ZIMXVoucher
 * @notice ERC721 voucher representing locked ZIMX tokens with unlock control and governance management.
 */
contract ZIMXVoucher is ERC721, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    /// @notice Timestamp when governance managed voucher features become available (2027-01-01 UTC).
    uint256 public constant GOVERNANCE_ENABLE_TS = 1_798_761_600;

    /// @notice ZIMX token that vouchers can be redeemed for.
    IERC20 public immutable token;
    /// @notice Governance address managing voucher issuance.
    address public governance;
    /// @notice Address nominated to assume governance pending acceptance.
    address public pendingGovernance;
    /// @notice Escrow wallet supplying tokens upon redemption.
    address public escrow;
    /// @notice Remaining token amount permitted to be pulled from the escrow wallet.
    uint256 public escrowRedemptionAllowance;
    /// @notice Counter for voucher token IDs.
    Counters.Counter private _ids;

    struct VoucherInfo {
        uint256 amount;
        uint64 unlockTimestamp;
        bool redeemed;
    }

    /// @notice Mapping from voucher ID to its information.
    mapping(uint256 => VoucherInfo) public vouchers;

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

    /// @notice Emitted when governance is transferred.
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    /// @notice Emitted when a voucher is minted.
    event VoucherMinted(uint256 indexed tokenId, address indexed to, uint256 amount, uint64 unlockTimestamp);
    /// @notice Emitted when a voucher is redeemed for tokens.
    event VoucherRedeemed(uint256 indexed tokenId, address indexed to, uint256 amount);
    /// @notice Emitted when the escrow wallet is updated.
    event EscrowUpdated(address indexed newEscrow);
    /// @notice Emitted when governance transfer is initiated.
    event GovernanceTransferStarted(address indexed currentGovernance, address indexed pendingGovernance);
    /// @notice Emitted when a pending governance transfer is cancelled.
    event GovernanceTransferCancelled(address indexed cancelledGovernance);
    /// @notice Emitted when an on-chain promise is recorded.
    event OnChainPromiseRecorded(uint256 indexed promiseId, string details);
    /// @notice Emitted when a promise status is updated.
    event OnChainPromiseStatusUpdated(uint256 indexed promiseId, PromiseStatus status);
    /// @notice Emitted when the redemption allowance sourced from escrow is adjusted.
    event EscrowRedemptionAllowanceSet(uint256 amount);
    /// @notice Emitted when a voucher is issued via governance.
    event VoucherIssued(bytes32 indexed code, address indexed issuer, uint256 amount, address indexed intendedBeneficiary);
    /// @notice Emitted when a voucher is redeemed.
    event VoucherRedeemed(bytes32 indexed code, address indexed redeemer, uint256 amount);

    modifier onlyGovernance() {
        require(msg.sender == governance, "NOT_GOVERNANCE");
        _;
    }

    modifier after2027() {
        require(block.timestamp >= GOVERNANCE_ENABLE_TS, "GOV_LOCKED_UNTIL_2027");
        _;
    }

    /**
     * @param token_ Address of the ZIMX token.
     * @param governance_ Governance multisig address.
     * @param escrow_ Address of the escrow wallet providing tokens on redemption.
     */
    constructor(IERC20 token_, address governance_, address escrow_) ERC721("ZIMX Voucher", "ZIMXV") {
        require(address(token_) != address(0), "TOKEN_ZERO");
        require(governance_ != address(0), "GOV_ZERO");
        require(escrow_ != address(0), "ESCROW_ZERO");
        token = token_;
        governance = governance_;
        escrow = escrow_;
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
     * @notice Updates the escrow wallet supplying redemption liquidity.
     * @param newEscrow New escrow wallet address.
     */
    function setEscrow(address newEscrow) external onlyGovernance after2027 {
        require(newEscrow != address(0), "ESCROW_ZERO");
        escrow = newEscrow;
        emit EscrowUpdated(newEscrow);
    }

    /**
     * @notice Sets the amount of tokens that can be redeemed from the escrow wallet.
     * @param amount Amount of tokens approved for redemption.
     */
    function setEscrowRedemptionAllowance(uint256 amount) external onlyGovernance after2027 {
        escrowRedemptionAllowance = amount;
        emit EscrowRedemptionAllowanceSet(amount);
    }

    /**
     * @notice Mints a voucher locking tokens for a beneficiary.
     * @param to Recipient of the voucher NFT.
     * @param amount Amount of tokens represented by the voucher.
     * @param unlockTimestamp Timestamp when redemption becomes available.
     * @return tokenId Identifier of the newly minted voucher.
     */
    function mint(address to, uint256 amount, uint64 unlockTimestamp)
        external
        onlyGovernance
        after2027
        returns (uint256 tokenId)
    {
        require(to != address(0), "ZERO_ADDRESS");
        require(amount > 0, "AMOUNT_ZERO");

        tokenId = _ids.current();
        _ids.increment();

        vouchers[tokenId] = VoucherInfo({amount: amount, unlockTimestamp: unlockTimestamp, redeemed: false});
        _safeMint(to, tokenId);
        emit VoucherMinted(tokenId, to, amount, unlockTimestamp);
        emit VoucherIssued(bytes32(tokenId), msg.sender, amount, to);
    }

    /**
     * @notice Redeems a voucher for its underlying tokens.
     * @param tokenId ID of the voucher to redeem.
     */
    function redeem(uint256 tokenId) external nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "NOT_OWNER");
        VoucherInfo storage info = vouchers[tokenId];
        require(!info.redeemed, "ALREADY_REDEEMED");
        require(block.timestamp >= info.unlockTimestamp, "VOUCHER_LOCKED");

        uint256 amount = info.amount;
        require(escrowRedemptionAllowance >= amount, "ALLOWANCE_EXCEEDED");
        info.redeemed = true;
        escrowRedemptionAllowance -= amount;
        _burn(tokenId);
        token.safeTransferFrom(escrow, msg.sender, amount);

        emit VoucherRedeemed(tokenId, msg.sender, amount);
        emit VoucherRedeemed(bytes32(tokenId), msg.sender, amount);
    }

    /**
     * @notice Records a new on-chain promise for the voucher program.
     * @param details Description of the commitment being made.
     * @return promiseId Identifier assigned to the promise.
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
     * @param status New status to assign.
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
     * @notice Retrieves details for a stored promise.
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
}
