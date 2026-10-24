# Concept & Mathematical Formulas - FairDot

## Core Principle

> **"Your principal always belongs to you. Outsized profits are enjoyed together, not taken alone."**

This system does not prevent anyone from getting rich. It only ensures **nobody can crash the market while exiting**, so all parties - early holders, late entrants, and whales - share the upside fairly.

---

## Core Formulas

### 1. Weighted-Average Entry Price (Value-Weighted)

Each user has their own "entry price," computed as the **value-weighted average** of all their buys:

```
P_entry = Σ(Amount_i × Price_i) / Σ(Amount_i)
```

Where:
- `Amount_i` = tokens bought in transaction i
- `Price_i` = price per token in transaction i
- Invested value per buy = `Amount_i × Price_i / 10^18`

**Important:** This is a **value-weighted** average, not a simple arithmetic average.

**Example:**
- Buy 1,000 tokens @ price 1.0 -> invested value = 1,000
- Buy 1,000 tokens @ price 3.0 -> invested value = 3,000
- Weighted-average entry = (1×1,000 + 3×1,000) / (1,000 + 1,000) = **2.5**

**Purpose:** Buying in batches at different prices doesn't distort the entry price - it always reflects the actual capital deployed.

### 2. Principal Value vs Current Value

```
Value_principal  = Total_Tokens × P_entry
Value_current    = Total_Tokens × P_current
Profit           = Value_current - Value_principal
```

### 3. Price Ratio (Trigger)

```
R = P_effective / P_entry
```

`P_effective` = 24h volume-weighted average price (not spot price - anti-manipulation):

```
P_effective = Σ(P_t × Volume_t) / Σ(Volume_t)   for the last 24 hours
```

| R | Mode | Rule |
|---|---|---|
| < 5 | Normal | 100% freely withdrawable |
| >= 5 | Protection | Principal free, profit released gradually |

### 4. Splitting Tokens: Principal vs Profit

```
Token_principal = Value_principal / P_current   -> ALWAYS freely withdrawable
Token_profit    = Total_Tokens - Token_principal -> released gradually
```

### 5. Gradual Profit Release (10 days)

After lock activates (day 0):

```
On day t:
  Tokens_released_daily = Token_profit / 10
  Tokens_locked(t)      = Token_profit × (1 - t/10)
  Tokens_withdrawable   = Token_principal + Σ(days 0..t) Tokens_released_daily
```

- Day 0: principal + 0% profit
- Day 1: principal + 10% profit
- Day 5: principal + 50% profit
- Day 10: principal + 100% profit = EVERYTHING free

### 6. Large-Withdrawal Stagger

```
L_ratio = Withdrawal_Value / Total_Liquidity

If L_ratio <= 10%   -> instant (1 part)
If 10% < L_ratio <= 30% -> 3 parts, 8h apart
If L_ratio > 30%   -> 10 parts, 1 day apart
```

### 7. Entry-Price Inheritance (Anti-Bypass)

When tokens move from wallet A to B:

```
share = Amount_transferred / (Balance_A + Amount_transferred)
Invested_inherited = Total_Invested_A × share

P_entry_B = (P_entry_B × Invested_B + P_entry_A × Invested_inherited)
            / (Invested_B + Invested_inherited)
Invested_B += Invested_inherited
Invested_A -= Invested_inherited
```

**Result:** Moving wallets CANNOT reset entry price. Rules always apply.

---

## PortaldotV3 Deployment Notes

- **Native token:** tPOTv3 (14 decimals on Substrate side; EVM layer scales to 18)
- **Storage deposit:** ~0.08 tPOTv3 per byte of deployed code
- **Size optimization:** compiler settings minimize bytecode (optimizer runs=1, viaIR, shanghai, no metadata)
- **Funding:** Map H160 -> SS58 via Node Console `reviveApi.accountId`, send tPOTv3 to SS58 address

---

## Example Scenario

### Setup
- Initial price = $1
- Liquidity = $100,000

### Early Holder (bought at $1)
- Principal = $1,000 -> holds 1,000 tokens
- Price moons to $10 -> ratio = 10x -> protection active
- Token_principal = $1,000 / $10 = 100 tokens -> **free immediately** (gets back full principal)
- Token_profit = 900 tokens -> released 90 tokens/day
- Day 1: can withdraw 190 tokens = $1,900 (1.9x principal)
- Day 5: can withdraw 550 tokens = $5,500 (5.5x principal)
- Day 10: all 1,000 tokens free = $10,000 (10x principal)

### Late Entrant (bought at $10, after the 10x moon)
- Principal = $1,000 -> holds 100 tokens
- P_entry = $10
- If price stays at $10 -> ratio = 1x -> **NORMAL, fully free to withdraw**
- If price moons again to $50 -> ratio = 5x -> protection active
  - Token_principal = $1,000 / $50 = 20 tokens -> free immediately
  - Token_profit = 80 tokens -> released 8 tokens/day
  - **Same profit ratio as the early holder!**

---

## Why This System Is Better

| Aspect | Normal Market | FairDot |
|---|---|---|
| First exit | Dumps everything, crashes price | Can only sell gradually, price holds |
| Late entrants | Buy the top, get rekt | Principal safe, profit fairly computed |
| Whales | Buy the top, get left behind | Nobody exits first -> exits with full profit |
| Rally duration | Minutes -> crashes | Days -> everyone participates |
| Market trust | Low (many get rekt) | High (everyone feels treated fairly) |
