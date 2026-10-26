# FairDot — Concept & Mathematical Model

## 1. Purpose

FairDot explores a position-aware exit model for memecoin trading. Instead of treating every token in a wallet as identical for withdrawal purposes, the contract records token purchases, estimates the holder’s quote-denominated cost basis, and applies a time-based release rule to tracked gains after a defined price threshold is reached.

The guiding idea is:

> **A holder’s purchase history should follow the position, and outsized gains should be released over time rather than all at once.**

This is a market-rule experiment, not a guarantee that holders will recover their principal, realize a profit, or be able to sell at a particular price.

## 2. Scope and terminology

The current implementation uses one configured contract pool and native `tPOTv3` as its quote asset. A **tracked position** is token inventory associated with buys recorded by that pool. **Untracked inventory** includes the initial distribution, owner-minted tokens, and other tokens without a recorded buy cost basis. Untracked inventory is not sellable through the pool as tracked inventory.

The model distinguishes:

- **Tracked tokens** — the quantity associated with recorded purchase cost.
- **Total invested** — the accumulated quote-denominated cost basis reported by the pool.
- **Average entry price** — total invested divided by tracked tokens.
- **Effective price** — a recent pool price measure used to estimate principal and the protection ratio.
- **Principal-equivalent tokens** — the number of tracked tokens whose current effective-price value equals the recorded cost basis. This is a token quantity, not a promise of quote-asset recovery.

## 3. Cost-basis formula: token-quantity-weighted average

For buys `i = 1 ... n`, let:

- `Aᵢ` = token amount bought in transaction `i`;
- `Pᵢ` = pool-reported quote price per token for that buy;
- `Cᵢ = Aᵢ × Pᵢ / 10¹⁸` = quote-denominated cost attributed to that buy.

Then:

```text
TotalInvested = Σ Cᵢ
TrackedTokens = Σ Aᵢ
AverageEntryPrice = TotalInvested × 10¹⁸ / TrackedTokens
```

Equivalently, ignoring fixed-point rounding:

```text
AverageEntryPrice = Σ(Aᵢ × Pᵢ) / Σ(Aᵢ)
```

This is weighted by the **number of tokens acquired**, not by the amount of money spent on each purchase and not by a simple average of transaction prices.

### Example

- Buy 100 tokens at 1 quote unit per token: cost = 100 quote units.
- Buy 100 tokens at 3 quote units per token: cost = 300 quote units.
- Total cost = 400 quote units; total tracked tokens = 200.
- Average entry price = `400 / 200 = 2` quote units per token.

The example illustrates the selected cost-basis rule: the average entry price is the total quote cost divided by the total token quantity.

## 4. Effective price and protection ratio

The pool records a price and quote volume for each buy and sell. FairDot computes a 24-hour quote-volume-weighted average from the price observations recorded during that period:

```text
EffectivePrice = Σ(Priceⱼ × QuoteVolumeⱼ) / Σ(QuoteVolumeⱼ)
```

If the 24-hour window contains no observations, the contract can use the latest recorded price only while that observation is no more than 24 hours old. If price data is unavailable or too old, the effective price is zero and tracked tokens are not withdrawable through the normal pool path until fresh observations exist.

For a holder with a recorded entry price:

```text
ProtectionRatio = EffectivePrice / AverageEntryPrice
```

The implementation uses fixed-point arithmetic and activates the protection condition at a ratio of `5×` or greater.

| Protection ratio | Tracked-token rule |
| --- | --- |
| Below `5×` | All tracked tokens are withdrawable, subject to fresh price data and successful pool execution. |
| `5×` or greater | The principal-equivalent tracked token quantity remains available; tracked profit tokens release over time. |

The 24-hour weighting smooths observations; it does not make the price manipulation-proof. The price history comes from the configured pool, not an independent oracle.

## 5. Principal-equivalent tokens and profit tokens

At the current effective price:

```text
PrincipalTokens = min(TrackedTokens, TotalInvested × 10¹⁸ / EffectivePrice)
ProfitTokens    = TrackedTokens − PrincipalTokens
```

The `min` prevents the principal quantity from exceeding the tracked balance. These values are calculated in token units. They do not promise that selling those tokens will return the same amount of quote asset, because pool depth, price impact, rounding, and market conditions affect execution.

### Example at the protection threshold

Assume a position has 200 tracked tokens and a total cost basis of 400 quote units. Its average entry price is 2 quote units per token. If the effective price reaches 10 quote units, the ratio is `5×`:

```text
PrincipalTokens = 400 / 10 = 40 tokens
ProfitTokens    = 200 − 40 = 160 tokens
```

The 40 principal-equivalent tokens are available under the contract’s withdrawal rules. The 160 profit tokens are subject to the release schedule below.

## 6. Profit-release schedule

The configured release duration is ten days. The first protected sell attempt routed through the configured pool starts the holder’s timer if no timer is already active. During the schedule, the amount released increases linearly:

```text
ReleasedProfit(t) = LockedProfitAtActivation × elapsedTime / 10 days
```

The released amount is capped by the holder’s currently calculated profit-token balance. At ten days, the currently calculated tracked profit-token amount is treated as released.

For the example above, if the price and position remain unchanged:

| Elapsed time | Principal-equivalent tokens | Approx. released profit tokens | Approx. total withdrawable tracked tokens |
| --- | ---: | ---: | ---: |
| At activation | 40 | 0 | 40 |
| 1 day | 40 | 16 | 56 |
| 5 days | 40 | 80 | 120 |
| 10 days | 40 | 160 | 200 |

These figures illustrate token accounting only. They do not account for pool slippage or the separate large-withdrawal schedule.

### State changes that matter

- A fresh price below the `5×` threshold clears the active lock and makes the tracked balance withdrawable under normal mode.
- A new recorded buy resets the aggregate position’s lock timer state; a later protected sell attempt may start a new schedule for the combined position.
- Transfers move tracked and untracked inventory proportionally. Transferred locked-profit accounting follows the transferred tracked position.
- A stale or unavailable effective price prevents a normal pool sale until fresh price observations become available.

These rules make the behavior explicit, but repeated price cycles and mixed-age positions remain important cases for further specification and testing.

## 7. Large-withdrawal schedule

The pool reports its quote reserve to the token contract. For an intended withdrawal, FairDot estimates its quote value using the effective price and compares it with the recorded quote reserve:

```text
WithdrawalValue = TokenAmount × EffectivePrice / 10¹⁸
WithdrawalRatio = WithdrawalValue / QuoteReserve
```

The configured thresholds are:

| Intended withdrawal value | Requirement |
| --- | --- |
| `≤ 10%` of quote reserve | One immediate sale; no schedule required. |
| `> 10%` and `≤ 30%` | Three equal installments, with 8 hours between installments. |
| `> 30%` | Ten installments, with 24 hours between installments. |

A holder must explicitly create a schedule for an amount that requires one. Each installment must match the scheduled amount, and wallet transfers are blocked while that holder has an active schedule.

The thresholds are evaluated for a specific wallet and withdrawal. Repeated smaller sales or splitting holdings across wallets are not fully prevented by this design. A schedule is not a global queue and does not reserve a stable price or quote amount.

## 8. Transfer policy: the single-approved-pool model

FairDot follows the selected **Policy B**:

1. Only the configured pool can move tokens into or out of its own address as part of market transactions.
2. Contract-address trading routes other than that pool are rejected.
3. Ordinary wallet-to-wallet transfers are permitted and carry the position accounting proportionally.
4. A transfer does not create a buy record or cost basis for untracked tokens.
5. Tokens without recorded cost basis cannot be sold through the pool as tracked tokens.

This policy is intentionally less composable than a standard unrestricted ERC-20 market. It is designed to keep this implementation’s accounting tied to a single known pool, not to support arbitrary routers, exchanges, or contract wallets.

## 9. Launch and supply behavior

The initial supply and any tokens minted before minting is disabled are recorded as untracked inventory. The owner may disable minting once; after that, the contract has no function to re-enable it. Trading can only be enabled after a pool is configured, initial liquidity is confirmed, and minting is disabled.

The deployment script can optionally perform the initial seed if both `INITIAL_LIQUIDITY_TOKEN_AMOUNT` and `INITIAL_LIQUIDITY_TPOT` are supplied. Without both values, it leaves trading disabled and does not seed or disable minting.

## 10. Design boundaries to keep visible

FairDot’s rules apply to the configured pool and the contract’s recorded state. They do not ensure that there will be buyers, that the pool has enough quote liquidity, or that any sale will execute at the displayed effective price. The mock pool has no swap fee and is not an oracle or a general-purpose DEX.

Additional behavior that should remain explicit in the product and further tests includes repeated small withdrawals, wallet splitting, repeated price cycles, mixed-age positions, pool-reserve changes after schedule creation, unbounded growth of the price-history array, owner/pool trust, and lack of a liquidity-provider lock mechanism.

## 11. Product statement

FairDot’s intended contribution is not “everyone is guaranteed to exit profitably.” It is a different set of transparent, position-aware rules for token withdrawals routed through one configured pool: record the purchase history, estimate principal in token units, and release outsized gains over time.
