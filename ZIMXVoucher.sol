// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ZIMXVoucher
 * @notice ERC721 voucher representing locked ZIMX tokens with unlock control and governance management.
 */
contract ZIMXVoucher is ERC721 {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    /// @notice ZIMX token that vouchers can be redeemed for.
    IERC20 public immutable token;
    /// @notice Governance address managing voucher issuance.
    address public governance;
    /// @notice Escrow wallet supplying tokens upon redemption.
    address public escrow;
    /// @notice Counter for voucher token IDs.
    Counters.Counter private _ids;

    struct VoucherInfo {
        uint256 amount;
        uint64 unlockTimestamp;
        bool redeemed;
    }

    /// @notice Mapping from voucher ID to its information.
    mapping(uint256 => VoucherInfo) public vouchers;

    /// @notice Emitted when governance is transferred.
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    /// @notice Emitted when a voucher is minted.
    event VoucherMinted(uint256 indexed tokenId, address indexed to, uint256 amount, uint64 unlockTimestamp);
    /// @notice Emitted when a voucher is redeemed for tokens.
    event VoucherRedeemed(uint256 indexed tokenId, address indexed to, uint256 amount);
    /// @notice Emitted when the escrow wallet is updated.
    event EscrowUpdated(address indexed newEscrow);

    modifier onlyGovernance() {
        require(msg.sender == governance, "NOT_GOVERNANCE");
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
    function transferGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "GOV_ZERO");
        emit GovernanceTransferred(governance, newGovernance);
        governance = newGovernance;
    }

    /**
     * @notice Updates the escrow wallet supplying redemption liquidity.
     * @param newEscrow New escrow wallet address.
     */
    function setEscrow(address newEscrow) external onlyGovernance {
        require(newEscrow != address(0), "ESCROW_ZERO");
        escrow = newEscrow;
        emit EscrowUpdated(newEscrow);
    }

    /**
     * @notice Mints a voucher locking tokens for a beneficiary.
     * @param to Recipient of the voucher NFT.
     * @param amount Amount of tokens represented by the voucher.
     * @param unlockTimestamp Timestamp when redemption becomes available.
     * @return tokenId Identifier of the newly minted voucher.
     */
    function mint(address to, uint256 amount, uint64 unlockTimestamp) external onlyGovernance returns (uint256 tokenId) {
        require(to != address(0), "ZERO_ADDRESS");
        require(amount > 0, "AMOUNT_ZERO");

        tokenId = _ids.current();
        _ids.increment();

        vouchers[tokenId] = VoucherInfo({amount: amount, unlockTimestamp: unlockTimestamp, redeemed: false});
        _safeMint(to, tokenId);
        emit VoucherMinted(tokenId, to, amount, unlockTimestamp);
    }

    /**
     * @notice Redeems a voucher for its underlying tokens.
     * @param tokenId ID of the voucher to redeem.
     */
    function redeem(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "NOT_OWNER");
        VoucherInfo storage info = vouchers[tokenId];
        require(!info.redeemed, "ALREADY_REDEEMED");
        require(block.timestamp >= info.unlockTimestamp, "VOUCHER_LOCKED");

        info.redeemed = true;
        _burn(tokenId);
        token.safeTransferFrom(escrow, msg.sender, info.amount);

        emit VoucherRedeemed(tokenId, msg.sender, info.amount);
    }
}
