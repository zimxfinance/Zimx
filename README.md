# ZIMX Token Ecosystem

This repository contains the smart contracts powering the ZIMX token and its surrounding ecosystem.

## Contracts

- `ZIMXToken.sol` – ERC20 token with a fixed supply of 1,000,000,000 tokens (6 decimals). The entire supply is minted to a configurable treasury wallet on deployment. Transfers can be paused by the owner and holders may burn their tokens.
- `ZIMXPresale.sol` – Handles token sales in exchange for ETH or an ERC20 stablecoin. All funds are forwarded to the treasury and tokens are distributed directly from the treasury wallet. Supports configurable rates, start/end times, pausing and finalisation.
- `ZIMXVesting.sol` – Allows the owner to create linear vesting schedules for beneficiaries. Tokens are released linearly after a cliff and can be claimed by beneficiaries.
- `ZIMXVoucher.sol` – ERC721 NFTs representing locked ZIMX tokens. Vouchers can be transferred and redeemed by their owners to claim the underlying tokens.

All contracts use OpenZeppelin libraries and include NatSpec documentation and events for important state changes.
