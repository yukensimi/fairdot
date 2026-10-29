# FairDot — Target Concept & Mathematical Model

## Purpose and status

FairDot is intended as a reusable on-chain protocol for applying transparent exit rules through one canonical pool per memecoin. It is not one meme token or one website. The repository includes FairDot Factory/Registry contracts intended to create one token and one canonical pool for each memecoin. Once a shared Factory is deployed, independent platforms can read the same Registry and interact with identical token/pool addresses; platform identity itself cannot be enforced on-chain. No network deployment is claimed here.

> FairDot is designed to make memecoin exit rules more transparent and reduce the impact of large sell orders through one configured pool. It does not guarantee stable prices, recovery of the same quote value as a holder’s cost basis, or profit for every holder.

The mechanisms described here are implemented in the current repository and covered by local regression tests. This does not claim a network deployment, independent audit, or production readiness.

## 1. Position lots and entry cost

FairDot’s target accounting follows position lots rather than treating all tracked tokens in a wallet as one undifferentiated balance. For a lot `L`, define:

- `Q_L`: quote actually paid for the purchase(s) attributed to the lot;
- `T_L`: tracked tokens actually received for those quote payments;
- `Entry_L = Q_L / T_L`: quote cost per tracked token for the lot.

Purchases are grouped by **UTC calendar day**. While a lot remains open, same-day purchases can be included in it. Once a lot has been checkpointed, it is sealed; any later same-day purchase starts a separate lot. This preserves the entry and timer history that applied when the checkpoint occurred.

A holder’s consecutive purchases on the same UTC day may merge only into that holder’s latest open purchase lot. A checkpointed lot is sealed, and transferred lots are not merge candidates. A transfer carries the transferred quantity’s lot-level basis, timer, and associated accounting; partial transfers split each affected lot proportionally. Lots with different timers are not merged. When tokens are sold, FIFO selects the oldest eligible lot first. Untracked inventory—such as gifts, airdrops, or other tokens without a recorded pool purchase—does not acquire a cost basis simply by being held or transferred.

## 2. Price signal and volume qualification

The design uses a 24-hour quote-volume-weighted average price (VWAP) from observations of the canonical pool:

```text
VWAP24h = Σ(priceⱼ × quoteVolumeⱼ) / Σ(quoteVolumeⱼ)
```

Profit protection is not active until the observed 24-hour quote volume reaches the configured minimum:

```text
MinimumVolume = max(configuredPercentage × InitialQuoteSeed,
                    configuredAbsoluteQuoteVolume)
```

The absolute threshold is denominated in the configured quote asset (tPOT in the target Portaldot configuration). Both numeric inputs are chosen after the initial quote seed is known and fixed before deployment. The VWAP and volume qualification are pool-derived signals, not an independent oracle or manipulation-proof measure. Before the volume threshold is met, tracked tokens are not profit-locked, but they remain subject to the large-sale schedule.

For each lot with a valid entry price:

```text
ProtectionRatio_L = VWAP24h / Entry_L
```

A price signal is qualified for profit protection when minimum 24-hour volume is met and the ratio is at least `5×`.

## 3. Holder checkpoint and profit release

A holder can call `pool.checkpointLock()` separately to start the protection timer before selling. The pool also checkpoints the caller during a sell attempt, so omitting the separate call cannot bypass a qualified profit lock. If the requested amount is not eligible, the sale is deferred without reverting the checkpoint. The pool alone calls the corresponding token checkpoint. A protected position’s profit release is linear over ten days, at 10% per day:

```text
ReleasedProfit_L(t) = checkpointedProfit_L × min(elapsedEligibleTime / 10 days, 1)
```

Release is associated with the applicable lot and timer. A fresh qualified price below `5×` releases any remaining profit; amounts already released never become locked again. These are eligibility rules, not promises that eligible tokens can be sold for a particular amount of quote currency.

### Inactivity and stale emergency behavior

- If no pool trade occurs for more than 24 hours, the profit-release clock pauses. Previously released profit remains eligible.
- If no trade occurs for more than 7 days, the target enters `STALE_EMERGENCY_MODE`. Any still-open lots are checkpointed against the last valid price, and profit remains locked. Principal calculations explicitly use that last valid price rather than treating it as fresh.
- In stale emergency mode, the maximum withdrawal per rolling 24-hour period is 10% of the holder’s tracked balance at emergency-mode entry. Unused quota does not accrue or carry forward.

Emergency-mode eligibility is not a guaranteed payout: pool liquidity, transaction execution, and market conditions still apply.

## 4. Large-sale schedule

The pool evaluates the **full sale request**, including principal and profit, at schedule start. It estimates quote output and divides that estimate by the pool’s quote reserve:

```text
SaleRatio = EstimatedQuoteOutput(full requested token amount) / QuoteReserveAtScheduleStart
```

The schedule is created automatically for a sale request according to these bands:

| Estimated full-request quote output / quote reserve | Target schedule |
| --- | --- |
| `≤ 10%` | One part, attempted immediately; after success, 8-hour address-based cooldown |
| `> 10%` through `30%` | Three parts, 8 hours apart |
| `> 30%` | Ten parts, 24 hours apart |

The first part is attempted immediately. Part sizes are fixed in token units when the schedule starts; any rounding remainder is assigned to the last part. Each installment rechecks eligibility. If an installment is not eligible, it waits; the interval to the next installment starts only after a successful installment. While a schedule is active, other sales are blocked. The holder can cancel remaining installments, but cooldown measured from the last successful installment persists. Each successful one-part sale at or below 10% also starts an 8-hour cooldown for that address. Each later installment requires a holder transaction; no keeper is part of the target design.

A per-holder schedule is not a global queue and does not guarantee a price, quote amount, or successful payout. Its impact depends on the pool and on the aggregate behavior of participants.

## 5. Canonical pool, transfers, and inventory

The target design has one canonical pool per token. Contract routes through external AMM pools or routers are intended to be rejected so supported market transactions follow the same pool rules. EOA-to-EOA transfers remain allowed and carry/split lot accounting. Platform A and Platform B can use the same Registry entry and canonical token/pool addresses; the protocol cannot distinguish which platform’s UI initiated a call.

Team allocation is intended to follow separately published vesting and is not sellable through the pool in v1. Untracked gifts and airdrops do not gain cost basis. One canonical pool and v1 parameters become immutable after trading begins. A change to those rules requires a new token/contract and voluntary migration; there is no unilateral in-place parameter change in the target model.

## 6. Boundaries and non-goals

FairDot’s rules apply only to supported interactions with the canonical pool. The design does not prevent OTC/off-chain trading, market price losses, unregistered cross-chain representations, or rug pulls. It does not guarantee that quote liquidity exists or that a sale executes. V1 does not include a global queue, KYC/anti-sybil controls, LP lock, or keeper. Pool-reported prices and volume are not an independent oracle, and a volume threshold does not eliminate manipulation or market risk.

## Disclaimer

FairDot is an experimental market-mechanics design, not financial advice. A tracked cost basis is accounting information, not a claim that the holder can recover the same quote value. The protocol cannot assure stable prices, liquidity, successful exits, or profit. Any implementation requires code verification, testing, and independent security review before use with assets of value.
