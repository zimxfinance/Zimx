// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ZIMXPresale
 * @notice Handles the ZIMX token presale accepting ETH and stablecoins.
 */
contract ZIMXPresale is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice ZIMX token being sold.
    IERC20 public immutable token;
    /// @notice Stablecoin accepted for purchases (e.g. USDC).
    IERC20 public immutable stablecoin;
    /// @notice Number of decimals used by the stablecoin.
    uint8 public immutable stableDecimals;
    /// @notice Treasury wallet receiving all funds and tokens are sent from.
    address public treasury;

    /// @notice Tokens awarded per 1 stablecoin unit.
    uint256 public rateStable;
    /// @notice Tokens awarded per 1 ETH.
    uint256 public rateEth;

    /// @notice Start timestamp of the presale.
    uint64 public startTime;
    /// @notice End timestamp of the presale.
    uint64 public endTime;
    /// @notice Flag signalling the presale has been finalized.
    bool public finalized;

    /// @notice Emitted when tokens are purchased.
    /// @param buyer Address purchasing the tokens.
    /// @param paymentToken Token used for payment (zero address for ETH).
    /// @param amountPaid Amount of ETH or stablecoin spent.
    /// @param tokensBought Amount of ZIMX tokens purchased.
    event TokensPurchased(address indexed buyer, address indexed paymentToken, uint256 amountPaid, uint256 tokensBought);
    /// @notice Emitted when the presale is finalized.
    event PresaleFinalized();
    /// @notice Emitted when treasury wallet is updated.
    event TreasuryUpdated(address indexed newTreasury);
    /// @notice Emitted when rates are updated.
    event RatesUpdated(uint256 newRateStable, uint256 newRateEth);
    /// @notice Emitted when presale times are updated.
    event TimesUpdated(uint64 newStart, uint64 newEnd);

    /**
     * @param token_ Address of the ZIMX token.
     * @param stablecoin_ Address of the accepted stablecoin.
     * @param treasury_ Treasury wallet receiving funds and holding sale tokens.
     * @param rateStable_ Number of tokens per 1 stablecoin.
     * @param rateEth_ Number of tokens per 1 ETH.
     * @param start_ Presale start timestamp.
     * @param end_ Presale end timestamp.
     */
    constructor(
        IERC20 token_,
        IERC20 stablecoin_,
        address treasury_,
        uint256 rateStable_,
        uint256 rateEth_,
        uint64 start_,
        uint64 end_
    ) {
        require(address(token_) != address(0) && address(stablecoin_) != address(0), "Zero address");
        require(treasury_ != address(0), "Treasury zero");
        require(end_ > start_, "End before start");

        token = token_;
        stablecoin = stablecoin_;
        stableDecimals = IERC20Metadata(address(stablecoin_)).decimals();
        treasury = treasury_;
        rateStable = rateStable_;
        rateEth = rateEth_;
        startTime = start_;
        endTime = end_;
    }

    /**
     * @notice Purchase tokens with stablecoin.
     * @param amount Amount of stablecoin to spend (in smallest units).
     */
    function buyWithStable(uint256 amount) external nonReentrant whenNotPaused {
        require(!finalized, "Presale finalized");
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Presale inactive");
        require(amount > 0, "Amount zero");

        uint256 tokensToBuy = (amount * rateStable) / (10 ** stableDecimals);
        stablecoin.safeTransferFrom(msg.sender, treasury, amount);
        token.safeTransferFrom(treasury, msg.sender, tokensToBuy);
        emit TokensPurchased(msg.sender, address(stablecoin), amount, tokensToBuy);
    }

    /**
     * @notice Purchase tokens with ETH.
     */
    function buyWithEth() external payable nonReentrant whenNotPaused {
        require(rateEth > 0, "ETH not accepted");
        require(!finalized, "Presale finalized");
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Presale inactive");
        require(msg.value > 0, "No ETH sent");

        uint256 tokensToBuy = (msg.value * rateEth) / 1 ether;
        (bool sent, ) = treasury.call{value: msg.value}("");
        require(sent, "ETH transfer failed");
        token.safeTransferFrom(treasury, msg.sender, tokensToBuy);
        emit TokensPurchased(msg.sender, address(0), msg.value, tokensToBuy);
    }

    /**
     * @notice Finalizes the presale preventing further purchases.
     */
    function finalize() external onlyOwner {
        finalized = true;
        emit PresaleFinalized();
    }

    /**
     * @notice Updates the treasury wallet.
     * @param newTreasury Address of the new treasury wallet.
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Treasury zero");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @notice Updates token rates for purchases.
     * @param newRateStable New number of tokens per 1 stablecoin.
     * @param newRateEth New number of tokens per 1 ETH.
     */
    function setRates(uint256 newRateStable, uint256 newRateEth) external onlyOwner {
        rateStable = newRateStable;
        rateEth = newRateEth;
        emit RatesUpdated(newRateStable, newRateEth);
    }

    /**
     * @notice Updates presale start and end times.
     * @param newStart New start timestamp.
     * @param newEnd New end timestamp.
     */
    function setTimes(uint64 newStart, uint64 newEnd) external onlyOwner {
        require(newEnd > newStart, "End before start");
        startTime = newStart;
        endTime = newEnd;
        emit TimesUpdated(newStart, newEnd);
    }

    /**
     * @notice Pause purchases.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause purchases.
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
