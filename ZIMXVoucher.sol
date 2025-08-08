// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ZIMXVoucher
 * @notice ERC721 voucher representing locked ZIMX tokens.
 */
contract ZIMXVoucher is ERC721, Ownable {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    /// @notice ZIMX token that vouchers can be redeemed for.
    IERC20 public immutable token;
    /// @notice Treasury wallet providing locked tokens.
    address public treasury;
    /// @notice Counter for voucher token IDs.
    Counters.Counter private _ids;

    struct VoucherInfo {
        uint256 amount;   // amount of tokens locked by this voucher
        bool redeemed;    // whether the voucher has been redeemed
    }

    /// @notice Mapping from voucher ID to its information.
    mapping(uint256 => VoucherInfo) public vouchers;

    /// @notice Emitted when a voucher is minted.
    event VoucherMinted(uint256 indexed tokenId, address indexed to, uint256 amount);
    /// @notice Emitted when a voucher is redeemed for tokens.
    event VoucherRedeemed(uint256 indexed tokenId, address indexed to, uint256 amount);
    /// @notice Emitted when treasury wallet is updated.
    event TreasuryUpdated(address indexed newTreasury);

    /**
     * @param token_ Address of the ZIMX token.
     * @param treasury_ Address of the treasury wallet providing tokens.
     */
    constructor(IERC20 token_, address treasury_) ERC721("ZIMX Voucher", "ZIMXV") {
        require(address(token_) != address(0) && treasury_ != address(0), "Zero address");
        token = token_;
        treasury = treasury_;
    }

    /**
     * @notice Mints a voucher locking tokens from the treasury.
     * @param to Recipient of the voucher NFT.
     * @param amount Amount of tokens locked in the voucher.
     * @return tokenId Identifier of the newly minted voucher.
     */
    function mint(address to, uint256 amount) external onlyOwner returns (uint256 tokenId) {
        require(to != address(0), "Zero address");
        require(amount > 0, "Amount zero");
        token.safeTransferFrom(treasury, address(this), amount);

        tokenId = _ids.current();
        _ids.increment();
        vouchers[tokenId] = VoucherInfo({amount: amount, redeemed: false});
        _safeMint(to, tokenId);
        emit VoucherMinted(tokenId, to, amount);
    }

    /**
     * @notice Redeems a voucher for its underlying tokens.
     * @param tokenId ID of the voucher to redeem.
     */
    function redeem(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "Not owner");
        VoucherInfo storage info = vouchers[tokenId];
        require(!info.redeemed, "Already redeemed");

        info.redeemed = true;
        token.safeTransfer(msg.sender, info.amount);
        _burn(tokenId);
        emit VoucherRedeemed(tokenId, msg.sender, info.amount);
    }

    /**
     * @notice Updates the treasury wallet address.
     * @param newTreasury New treasury wallet.
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Zero address");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }
}
