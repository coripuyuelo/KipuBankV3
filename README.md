# KipuBankV3

Smart contract that extends **KipuBankV2** into a more realistic DeFi vault.  
This version allows users to deposit native ETH, USDC, or **any ERC-20 token that has a direct pair with USDC on Uniswap V2**.  
Non-USDC tokens are automatically swapped to USDC via the Uniswap V2 router and then credited to the user’s balance, while preserving the original bank cap logic.

This project is part of Module 4 of the **Ethereum Developer Pack – Fundación Kipu**.

---

## 1. High-level overview

`KipuBankV3` simulates a production-like DeFi protocol:

- Users can fund their personal vaults using multiple asset types.  
- The contract integrates with **Uniswap V2** to normalize all balances into **USDC**, enabling a single-currency cap model.  
- The original constraints from `KipuBankV2` (balance tracking, global cap, secure withdrawals, events, custom errors) are preserved.  
- The code is documented so that auditors and frontends can understand the protocol surface and interact safely.

---

## 2. What changed from KipuBankV2

**KipuBankV2** handled only native ETH. It enforced:
- a global cap (`bankCap`),
- a per-tx withdrawal limit,
- operation counters per user,
- and a simple reentrancy guard.

**KipuBankV3** keeps all of that but adds:

1. **Generalized deposits**  
   - `depositETH()` or payable `deposit()` – swaps or credits ETH to USDC.  
   - `depositUSDC(uint256 amount)` – credits directly.  
   - `depositToken(address token, uint256 amount)` – swaps any ERC-20 to USDC using Uniswap V2.

2. **Uniswap V2 integration**  
   - Contract holds a router reference.  
   - Performs token → USDC swaps within one transaction.  
   - Only tokens with a **direct USDC pair** are supported.

3. **Bank cap in USDC**  
   - Cap enforced **after swap**, based on the resulting USDC amount.

4. **Backward-compatible logic**  
   - Withdrawals, events, and errors preserved.  
   - Ownership logic (if present in V2) maintained.  

---

## 3. Contract architecture

### Main components
- `uint256 public immutable bankCap;`  
- `uint256 public immutable withdrawalLimit;`  
- `uint256 public totalDeposits;` // in USDC units  
- `mapping(address ⇒ uint256) balances;`  
- `address public immutable uniswapV2Router;`  
- `address public immutable usdc;`

### Core functions
- `depositETH()` or `receive()` → swap ETH to USDC.  
- `depositUSDC(uint256 amount)` → direct credit.  
- `depositToken(address token, uint256 amount)` → swap to USDC.  
- `withdraw(uint256 amount)` → transfer USDC back respecting `withdrawalLimit`.

---

## 4. Flow of a deposit with swap

1. User calls `depositToken(token, amount)` after `approve`.  
2. Contract pulls tokens.  
3. Builds swap path `[token, USDC]`.  
4. Calls Uniswap V2 router.  
5. Receives `usdcOut`.  
6. Checks `totalDeposits + usdcOut ≤ bankCap`.  
7. Updates balance and totalDeposits.  
8. Emits `Deposit(user, usdcOut)`.

All balances inside the bank are in USDC.

---

## 5. Deployment

### Requirements
- **Foundry** (`forge`)  
- Wallet with test ETH and USDC  
- Uniswap V2 router address (Sepolia network)  
- USDC token address

### Compile
```bash
forge build
```

### Deploy (example)
```bash
forge create src/KipuBankV3.sol:KipuBankV3 \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --constructor-args 25000000000000000000000 1000000000000000000 $UNISWAP_ROUTER $USDC_ADDRESS
```

### Verify
After deployment, verify the contract on Etherscan / Routescan / Blockscout.
```bash
forge create src/KipuBankV3.sol:KipuBankV3 \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --constructor-args 25000000000000000000000 1000000000000000000 $UNISWAP_ROUTER $USDC_ADDRESS
```

**Verified contract URL:** `https://...`

---

## 6. Interaction

### Deposit USDC
```solidity
USDC.approve(kipuBankV3, amount);
kipuBankV3.depositUSDC(amount);
```

### Deposit ERC-20 (to be swapped)
```solidity
token.approve(kipuBankV3, amount);
kipuBankV3.depositToken(token, amount);
```

### Deposit native ETH
```solidity
kipuBankV3.deposit{value: 1 ether}();
```

### Withdraw
```solidity
kipuBankV3.withdraw(500e6);
```

---

## 7. Design decisions & trade-offs
- **Single-currency accounting (USDC):** simplifies TVL tracking.  
- **Direct pairs only:** avoids multi-hop swap risks.  
- **Immutable router address:** minimizes attack surface.  
- **Reentrancy guard:** keeps DeFi-standard protection.  
- **Cap post-swap:** ensures max TVL never exceeded.

---

## 8. Threat analysis

**Identified weaknesses**
- Potential slippage / price manipulation on Uniswap V2.  
- Unsupported tokens (without USDC pair) cause failed swaps.  
- Reliance on USDC peg (USDC de-peg would affect balances).  
- Admin/owner surface (if enabled) must be trusted.  

**Missing steps for production maturity**
- Add user-controlled `amountOutMin` for slippage protection.  
- Add pause/emergency withdraw feature.  
- Integrate price oracle or TWAP for swap validation.  
- Expand test suite with edge cases and revert paths.  

**Test methods**
- Local unit tests with Foundry: `forge test`  
- Coverage report: `forge coverage`  
- Manual interaction on Sepolia to validate router integration.  

**Test coverage**
- Required: ≥ 50 %  
- Final value (after coverage run): `XX %`

---

## 9. Testing & coverage
```bash
forge test
forge coverage
```
Tests should validate:
- deposits (USDC / ERC-20 / ETH)  
- deposit > bankCap → revert  
- withdrawals and limits  
- reentrancy protection  

---

## 10. Repository structure
```text
.
├── src
│   └── KipuBankV3.sol
├── test
│   └── KipuBankV3.t.sol
├── foundry.toml
├── README.md
└── lib
    └── (dependencies: forge-std, uniswap-v2 interfaces, etc.)
```

---

## 11. Links
- **GitHub repo:** `<to be filled>`  
- **Verified contract URL:** `<to be filled>`
