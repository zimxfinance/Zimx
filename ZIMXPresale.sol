// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IERC20Burnable is IERC20 {
    function burn(uint256 value) external;
}

/**
 * @title ZIMXPresale
 * @notice Handles the ZIMX token presale accepting ETH and stablecoins with KYC enforcement,
 * caps and a final reserve split.
 */
contract ZIMXPresale is Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Total number of tokens that can be sold via the presale (6 decimals).
    uint256 public constant HARD_CAP = 50_000_000 * 10 ** 6;

    /// @notice Address responsible for privileged governance actions (intended multisig).
    address public governance;

    /// @notice ZIMX token being sold.
    IERC20 public immutable token;
    /// @notice Stablecoin accepted for purchases (e.g. USDC).
    IERC20 public immutable stablecoin;
    /// @notice Number of decimals used by the stablecoin.
    uint8 public immutable stableDecimals;

    /// @notice Maximum tokens a single buyer can acquire (6 decimals).
    uint256 public buyerMax = 500_000 * 10 ** 6;
    /// @notice Portion of proceeds sent to the reserve vault (basis points).
    uint16 public reserveBps = 5000;

    /// @notice Destination receiving the locked reserve share of proceeds.
    address public reserveVault;
    /// @notice Destination receiving the operations share of proceeds.
    address public opsTreasury;

    /// @notice Mapping of buyer to amount of tokens purchased.
    mapping(address => uint256) public contributionOf;
    /// @notice Mapping tracking whether a buyer has completed KYC.
    mapping(address => bool) public kycPassed;

    /// @notice Start timestamp of the presale.
    uint64 public startTime;
    /// @notice End timestamp of the presale.
    uint64 public endTime;
    /// @notice Flag signalling the presale has been finalized.
    bool public finalized;

    /// @notice Total number of tokens sold.
    uint256 public sold;
    /// @notice Total amount of stablecoin raised (in smallest units).
    uint256 public stableRaised;
    /// @notice Total amount of ETH raised (in wei).
    uint256 public ethRaised;

    /// @notice Whether unsold tokens should be burned on finalize.
    bool public burnUnsoldTokens;
    /// @notice Destination receiving unsold tokens when not burning.
    address public unsoldTokenRecipient;

    /// @notice Emitted when a purchase occurs during the sale.
    event SalePurchased(address indexed buyer, uint256 zimxAmount, uint256 paidAmount, address indexed paymentToken);
    /// @notice Emitted when the sale is closed to new purchases.
    event SaleClosed();
    /// @notice Emitted when the final split of proceeds is executed.
    event Finalized(
        uint256 totalSold,
        uint256 stableRaised,
        uint256 ethRaised,
        uint256 reserveStable,
        uint256 reserveEth,
        uint256 opsStable,
        uint256 opsEth
    );
    /// @notice Emitted when the proceeds vault addresses are updated.
    event VaultsUpdated(address indexed reserve, address indexed ops);
    /// @notice Emitted when the reserve split is adjusted.
    event ReserveSplitUpdated(uint16 newReserveBps);
    /// @notice Emitted when per-buyer caps are updated.
    event BuyerMaxUpdated(uint256 newBuyerMax);
    /// @notice Emitted when sale rates are updated.
    event RatesUpdated(uint256 newRateStable, uint256 newRateEth);
    /// @notice Emitted when sale times are updated.
    event TimesUpdated(uint64 newStart, uint64 newEnd);
    /// @notice Emitted when KYC status is changed for a participant.
    event KycStatusUpdated(address indexed participant, bool passed);
    /// @notice Emitted when unsold token handling is configured.
    event UnsoldConfigurationUpdated(bool burnUnsold, address indexed recipient);
    /// @notice Emitted when governance is transferred.
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);

    modifier onlyGovernance() {
        require(msg.sender == governance, "NOT_GOVERNANCE");
        _;
    }

    /**
     * @param governance_ Address holding governance control over the presale.
     * @param token_ Address of the ZIMX token.
     * @param stablecoin_ Address of the accepted stablecoin.
     * @param rateStable_ Number of tokens per 1 stablecoin.
     * @param rateEth_ Number of tokens per 1 ETH.
     * @param start_ Presale start timestamp.
     * @param end_ Presale end timestamp.
     * @param reserveVault_ Initial reserve vault address.
     * @param opsTreasury_ Initial operations treasury address.
     */
    constructor(
        address governance_,
        IERC20 token_,
        IERC20 stablecoin_,
        uint256 rateStable_,
        uint256 rateEth_,
        uint64 start_,
        uint64 end_,
        address reserveVault_,
        address opsTreasury_
    ) {
        require(governance_ != address(0), "GOV_ZERO");
        require(address(token_) != address(0) && address(stablecoin_) != address(0), "TOKEN_ZERO");
        require(end_ > start_, "END_BEFORE_START");
        governance = governance_;
        token = token_;
        stablecoin = stablecoin_;
        stableDecimals = IERC20Metadata(address(stablecoin_)).decimals();
        rateStable = rateStable_;
        rateEth = rateEth_;
        startTime = start_;
        endTime = end_;
        if (reserveVault_ != address(0) && opsTreasury_ != address(0)) {
            _setVaults(reserveVault_, opsTreasury_);
        }
    }

    /// @notice Current token rate when purchasing with the stablecoin (tokens per one stable unit).
    uint256 public rateStable;
    /// @notice Current token rate when purchasing with ETH (tokens per 1 ETH).
    uint256 public rateEth;

    /**
     * @notice Purchase tokens with the accepted stablecoin.
     * @param amount Amount of stablecoin to spend (in smallest units).
     */
    function buyWithStable(uint256 amount) external nonReentrant whenNotPaused {
        require(!finalized, "SALE_FINALIZED");
        require(block.timestamp >= startTime && block.timestamp <= endTime, "SALE_INACTIVE");
        require(amount > 0, "AMOUNT_ZERO");
        require(kycPassed[msg.sender], "KYC_REQUIRED");

        uint256 tokensToBuy = (amount * rateStable) / (10 ** stableDecimals);
        require(tokensToBuy > 0, "NO_TOKENS");
        _validatePurchase(msg.sender, tokensToBuy);

        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        token.safeTransfer(msg.sender, tokensToBuy);

        contributionOf[msg.sender] += tokensToBuy;
        sold += tokensToBuy;
        stableRaised += amount;

        emit SalePurchased(msg.sender, tokensToBuy, amount, address(stablecoin));
    }

    /**
     * @notice Purchase tokens with ETH.
     */
    function buyWithEth() external payable nonReentrant whenNotPaused {
        require(rateEth > 0, "ETH_DISABLED");
        require(!finalized, "SALE_FINALIZED");
        require(block.timestamp >= startTime && block.timestamp <= endTime, "SALE_INACTIVE");
        require(msg.value > 0, "NO_ETH");
        require(kycPassed[msg.sender], "KYC_REQUIRED");

        uint256 tokensToBuy = (msg.value * rateEth) / 1 ether;
        require(tokensToBuy > 0, "NO_TOKENS");
        _validatePurchase(msg.sender, tokensToBuy);

        token.safeTransfer(msg.sender, tokensToBuy);

        contributionOf[msg.sender] += tokensToBuy;
        sold += tokensToBuy;
        ethRaised += msg.value;

        emit SalePurchased(msg.sender, tokensToBuy, msg.value, address(0));
    }

    /**
     * @notice Finalizes the presale, preventing further purchases and splitting proceeds.
     * @param unsoldRecipient Address receiving unsold tokens when burning is disabled.
     */
    function finalize(address unsoldRecipient) external onlyGovernance nonReentrant {
        require(!finalized, "SALE_FINALIZED");
        require(block.timestamp > endTime, "SALE_NOT_ENDED");
        require(reserveVault != address(0) && opsTreasury != address(0), "VAULTS_NOT_SET");

        finalized = true;
        emit SaleClosed();

        uint256 stableBalance = stablecoin.balanceOf(address(this));
        uint256 ethBalance = address(this).balance;

        uint256 reserveStable = (stableBalance * reserveBps) / 10_000;
        uint256 opsStable = stableBalance - reserveStable;
        uint256 reserveEth = (ethBalance * reserveBps) / 10_000;
        uint256 opsEth = ethBalance - reserveEth;

        if (reserveStable > 0) {
            stablecoin.safeTransfer(reserveVault, reserveStable);
        }
        if (opsStable > 0) {
            stablecoin.safeTransfer(opsTreasury, opsStable);
        }
        if (reserveEth > 0) {
            (bool sentReserve, ) = reserveVault.call{value: reserveEth}("");
            require(sentReserve, "RESERVE_ETH_FAIL");
        }
        if (opsEth > 0) {
            (bool sentOps, ) = opsTreasury.call{value: opsEth}("");
            require(sentOps, "OPS_ETH_FAIL");
        }

        uint256 unsold = token.balanceOf(address(this));
        if (unsold > 0) {
            if (burnUnsoldTokens) {
                IERC20Burnable(address(token)).burn(unsold);
            } else if (unsoldRecipient != address(0)) {
                token.safeTransfer(unsoldRecipient, unsold);
            } else if (unsoldTokenRecipient != address(0)) {
                token.safeTransfer(unsoldTokenRecipient, unsold);
            }
        }

        emit Finalized(sold, stableRaised, ethRaised, reserveStable, reserveEth, opsStable, opsEth);
    }

    /**
     * @notice Updates the proceeds vault addresses (pre-finalization only).
     * @param reserve Address of the reserve vault.
     * @param ops Address of the operations treasury.
     */
    function setVaults(address reserve, address ops) external onlyGovernance {
        require(!finalized, "SALE_FINALIZED");
        _setVaults(reserve, ops);
    }

    /**
     * @notice Updates the reserve split (pre-finalization only).
     * @param newReserveBps New reserve basis points (0 - 10,000).
     */
    function setReserveSplit(uint16 newReserveBps) external onlyGovernance {
        require(!finalized, "SALE_FINALIZED");
        require(newReserveBps <= 10_000, "BPS_OOB");
        reserveBps = newReserveBps;
        emit ReserveSplitUpdated(newReserveBps);
    }

    /**
     * @notice Updates the maximum allocation per buyer (pre-finalization only).
     * @param newBuyerMax New maximum in token units (6 decimals).
     */
    function setBuyerMax(uint256 newBuyerMax) external onlyGovernance {
        require(!finalized, "SALE_FINALIZED");
        require(newBuyerMax > 0 && newBuyerMax <= HARD_CAP, "INVALID_MAX");
        buyerMax = newBuyerMax;
        emit BuyerMaxUpdated(newBuyerMax);
    }

    /**
     * @notice Updates token purchase rates (pre-finalization only).
     * @param newRateStable New number of tokens per 1 stablecoin.
     * @param newRateEth New number of tokens per 1 ETH.
     */
    function setRates(uint256 newRateStable, uint256 newRateEth) external onlyGovernance {
        require(!finalized, "SALE_FINALIZED");
        rateStable = newRateStable;
        rateEth = newRateEth;
        emit RatesUpdated(newRateStable, newRateEth);
    }

    /**
     * @notice Updates presale start and end times (pre-finalization only).
     * @param newStart New start timestamp.
     * @param newEnd New end timestamp.
     */
    function setTimes(uint64 newStart, uint64 newEnd) external onlyGovernance {
        require(!finalized, "SALE_FINALIZED");
        require(newEnd > newStart, "END_BEFORE_START");
        startTime = newStart;
        endTime = newEnd;
        emit TimesUpdated(newStart, newEnd);
    }

    /**
     * @notice Marks an account as having passed (or failing) KYC checks (pre-finalization only).
     * @param user Address of the participant.
     * @param ok Whether the participant passed KYC.
     */
    function setKycPassed(address user, bool ok) external onlyGovernance {
        require(!finalized, "SALE_FINALIZED");
        kycPassed[user] = ok;
        emit KycStatusUpdated(user, ok);
    }

    /**
     * @notice Configures handling of unsold tokens upon finalization.
     * @param burnUnsold Whether to burn unsold tokens to a terminal address.
     * @param recipient Recipient of unsold tokens when not burning.
     */
    function configureUnsold(bool burnUnsold, address recipient) external onlyGovernance {
        require(!finalized, "SALE_FINALIZED");
        if (burnUnsold) {
            require(recipient == address(0), "RECIPIENT_IGNORED");
        }
        burnUnsoldTokens = burnUnsold;
        unsoldTokenRecipient = recipient;
        emit UnsoldConfigurationUpdated(burnUnsold, recipient);
    }

    /**
     * @notice Pause purchases.
     */
    function pause() external onlyGovernance {
        _pause();
    }

    /**
     * @notice Unpause purchases.
     */
    function unpause() external onlyGovernance {
        _unpause();
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
     * @notice Internal helper to validate a purchase against limits.
     * @param buyer Address purchasing the tokens.
     * @param tokensToBuy Amount of tokens being purchased.
     */
    function _validatePurchase(address buyer, uint256 tokensToBuy) internal view {
        require(sold + tokensToBuy <= HARD_CAP, "HARD_CAP_REACHED");
        require(contributionOf[buyer] + tokensToBuy <= buyerMax, "BUYER_LIMIT");
    }

    function _setVaults(address reserve, address ops) internal {
        require(reserve != address(0) && ops != address(0), "VAULT_ZERO");
        reserveVault = reserve;
        opsTreasury = ops;
        emit VaultsUpdated(reserve, ops);
    }

}
