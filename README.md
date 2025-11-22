# BNB FX-Swap Synthetic Dollar (PoC)

## Overview
A minimal proof-of-concept protocol on BNB Chain / opBNB to create `bUSD`, a synthetic dollar backed by BNB collateral. The design is inspired by traditional Eurodollar FX swaps, utilizing fixed-term collateralized borrowing logic rather than perpetual delta-neutral hedging. This proves pure on-chain credit creation without relying on external liquidity for shorting.

## Core Philosophy
Unlike delta-neutral protocols that rely on shorting perp futures to maintain peg (which introduces counterparty and funding rate risks), this protocol uses an **over-collateralized debt position (CDP)** model framed as a **fixed-term FX swap**.

*   **Spot Leg:** User deposits BNB collateral and mints bUSD (effectively selling BNB for USD spot).
*   **Forward Leg:** User has an obligation to repurchase BNB (repay bUSD) at a future date or roll over the position.

## Architecture

### 1. Contracts
*   **`bUSD.sol`**: The synthetic dollar. A standard ERC20 token with restricted mint/burn access controlled by the Vault.
*   **`FXSwapVault.sol`**: The core engine.
    *   Manages BNB deposits.
    *   Issues bUSD based on collateral ratio.
    *   Tracks "Swap Positions" (Loans) with fixed maturities (e.g., 7 days, 30 days).
    *   **Helper:** `getUserPositions(address)` added to easily retrieve user's active position IDs for frontend display.
    *   **Status:** Completed (Deposit, Mint, Repay, Liquidate, Rollover).
    *   **`PriceOracle.sol`**: Wrapper around Chainlink AggregatorV3. Returns 18-decimal normalized price.# 2. Key Mechanisms
*   **Minting (Open Swap):** 
    *   User deposits BNB.
    *   System calculates Max Borrowable bUSD based on LTV (e.g., 66% LTV / 150% C-Ratio).
    *   User receives bUSD.
    *   A "Swap Position" is created with a `maturityTimestamp`.
*   **Rollover:**
    *   Before maturity, user can extend the term by paying a small fee.
    *   **Rate:** Fixed 5% APR (pro-rated) on the debt value.
    *   **Mechanism:** User pays BNB fee -> Maturity extended.
*   **Redemption (Close Swap):**
    *   User burns bUSD to unlock BNB collateral.
*   **Liquidation:**
    *   **Triggers:** 
        1.  **Bad Debt:** Health Factor < 1.0 (Approx < 125% Collateral Ratio).
        2.  **Expiration:** Position past maturity timestamp.
    *   **Incentive:** Liquidators receive **10% Bonus** in collateral.
    *   **Process:** Liquidator repays bUSD debt -> Seizes equivalent BNB collateral + Bonus.

## Implementation Plan
1.  **Setup:** Initialize Foundry project and clean defaults.
2.  **Architecture & Docs:** Define this plan.
3.  **bUSD Contract:** Implement restricted ERC20.
4.  **Oracle:** Implement Chainlink wrapper (utilizing real feeds via Forking).
5.  **Vault Core:** Implement Deposit, Borrow, and Position tracking (Completed).
6.  **Liquidation & Rolls:** Implement health checks and liquidation logic (Completed).
7.  **Verification:** Write Fork Tests against BNB Chain Mainnet (Completed).

## Tech Stack
*   **Language:** Solidity ^0.8.20
*   **Framework:** Foundry
*   **Libraries:** OpenZeppelin Contracts (ERC20, Ownable, ReentrancyGuard)
*   **Network:** BNB Chain / opBNB (Forked for testing)

## Future Roadmap (Beyond PoC)
*   **Dynamic Interest Rates:** Implement variable rates based on utilization or term length.
*   **Multi-Collateral Support:** Support ETH, BTCB, etc.
*   **Flash Minting:** Allow arbitrage opportunities to keep the peg tight.
*   **Governance:** DAO control for parameters (LTV, Liquidation Threshold, Oracle sources).
*   **Secondary Market:** Tokenize the "Swap Positions" (NFTs) so they can be traded.

## Usage
```shell
# Build
forge build

# Test (Fork Mode)
forge test --rpc-url <BNB_RPC_URL>
```

## Deployment & Frontend Plan

### 1. Deployment Script (`script/Deploy.s.sol`)
To deploy to BNB Testnet, we need a `script/Deploy.s.sol` that performs the following:
1.  **Load Environment Variables**: Retrieve deployer private key.
2.  **Derive Deployer Address**: Use `vm.addr(privateKey)` to strictly identify the EOA.
3.  **Deploy PriceOracle**: Initialize with the BNB Testnet Chainlink Aggregator address (`0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526` for BNB/USD).
4.  **Deploy bUSD**: Initialize with the explicit `deployer` address as owner (Fixes `OwnableUnauthorizedAccount` error caused by ambiguous `msg.sender`).
5.  **Deploy FXSwapVault**: Initialize with `bUSD` and `PriceOracle` addresses.
6.  **Transfer Ownership**: Call `bUSD.transferOwnership(vaultAddress)` to give the vault minting rights.
7.  **Verification**: Output addresses for verification on BscScan.

### 2. Minimal Frontend Interface
A minimal React-based frontend (Vite + Wagmi + RainbowKit) is required to interact with the protocol.

#### **Directory Structure**
```
frontend/
├── src/
│   ├── abis/              # Contract ABIs (FXSwapVault, bUSD, PriceOracle)
│   ├── components/        # UI Components (ConnectButton, VaultCard)
│   ├── hooks/             # Custom hooks for contract interaction
│   └── App.tsx            # Main UI
```

#### **Required Features**
1.  **Wallet Connection**: Connect MetaMask/Rabby via RainbowKit (BNB Testnet Chain ID: 97).
2.  **Dashboard**:
    *   Display User's BNB Balance.
    *   Display User's Active Position (Debt, Collateral, Maturity).
    *   Display Current Oracle Price.
3.  **Actions**:
    *   **Open Position**: Input amount -> `vault.openPosition{value: X}(amount, duration)`.
    *   **Repay**: `vault.repayPosition(id)`.
    *   **Liquidate**: Input ID -> `vault.liquidate(id)`.

### 3. Environment Setup
Required `.env` file in root:
```ini
BNB_TESTNET_RPC_URL=https://data-seed-prebsc-1-s1.binance.org:8545/
PRIVATE_KEY=0x...
ETHERSCAN_API_KEY=... (For BscScan verification)
```

### 4. Version Control
The project is initialized with Git. A `.gitignore` file is configured to exclude sensitive data and build artifacts:
*   **Ignored:** `.env` (Private Keys/RPCs), `out/`, `cache/`, `node_modules/`.
*   **Note:** Always check `.gitignore` before pushing to remote repositories to prevent leaking credentials.

### 5. Troubleshooting
*   **TypeScript ABI Errors:** If `npm run build` fails with `Type 'string' is not assignable to type '"function"'`, it's due to Wagmi's strict ABI typing vs JSON imports.
    *   **Fix:** Cast imported JSON ABIs to `any` or `Abi` type from `viem` in `App.tsx`.
*   **Address Type Errors:** Wagmi requires addresses to be strictly typed as `0x${string}`.
    *   **Fix:** Cast string constants to `as '0x${string}'`.
