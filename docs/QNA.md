# FairDot — Frequently Asked Questions

## Status and product scope

This Q&A describes the protocol behavior implemented in the current repository and covered by local regression tests. It does not claim a network deployment, independent audit, or production readiness.

> FairDot is designed to make memecoin exit rules more transparent and reduce the impact of large sell orders through one configured pool. It does not guarantee stable prices, recovery of the same quote value as a holder’s cost basis, or profit for every holder.

### What is FairDot?

FairDot is intended as a reusable on-chain protocol, not one meme token or website. The repository includes FairDot Factory/Registry contracts intended to create one token and one canonical pool per memecoin. Once a shared Factory is deployed, independent platforms can read the same Registry entry and interact with the same token and pool addresses. No Factory deployment is claimed here.

### Can FairDot enforce that trading happens through a particular platform?

No. Platform identity itself cannot be enforced on-chain. Any user interface calling a token’s canonical pool follows the same pool rules, whether it is Platform A, Platform B, or another interface. External AMM pool/router contract routes are intended to be rejected by the target design.

## Entry, lots, and protection

### How is entry price calculated?

For each tracked position lot, entry price is the quote actually paid divided by tracked tokens received:

```text
EntryPricePerLot = ActualQuotePaid / TrackedTokensReceived
```

Consecutive purchases by a holder are grouped by UTC calendar day only while adding to that holder’s latest open purchase lot. A checkpointed or transferred lot is not a merge candidate; a later purchase creates a separate lot.

### What happens when I transfer only part of a position?

EOA-to-EOA transfers remain allowed and carry or split each affected lot’s basis, timer, and accounting proportionally. Lots with different timers are not merged. Sales consume the oldest eligible lot first (FIFO). A transfer does not turn a gift, airdrop, or other untracked tokens into tracked tokens with a new cost basis.

### When does profit protection apply?

The target uses a 24-hour quote VWAP from the canonical pool. Profit protection requires both a minimum observed 24-hour quote volume and a price ratio of at least `5×` for the applicable lot:

```text
MinimumVolume = max(configured percentage × InitialQuoteSeed,
                    configured absolute tPOT)
ProtectionRatio = VWAP24h / LotEntryPrice
```

The numeric inputs are selected after the initial quote seed is chosen and fixed before deployment. Before the volume threshold is met, tracked tokens are not profit-locked, but they remain subject to the large-sale schedule. Pool-reported price and volume are not an independent oracle and cannot eliminate manipulation or market risk.

### Who starts a protection checkpoint?

A holder can call `pool.checkpointLock()` separately to start protection before selling. The pool also checkpoints the caller during a sell attempt, so a holder cannot bypass a qualified lock simply by skipping the separate call. If the requested amount is not eligible, the sale is deferred without reverting the checkpoint. The pool alone calls the token checkpoint. A checkpointed lot becomes sealed; a later purchase forms a new lot.

### How quickly is profit released?

The target releases profit linearly at 10% per day over 10 days. A fresh price below `5×` releases remaining profit. Profit that has already been released never re-locks. These rules define eligibility, not guaranteed sale proceeds.

### What happens if trading stops?

If no trade occurs for more than 24 hours, the profit-release clock pauses; profit previously released remains eligible. If there is no trade for more than 7 days, the target enters `STALE_EMERGENCY_MODE`: any still-open lots are checkpointed against the last valid price, profit stays locked, and that price is explicitly used for principal calculations. The withdrawal cap is 10% of tracked balance at emergency entry per rolling 24 hours. Unused quota does not accrue. Emergency eligibility is not a guaranteed payout.

### Is my principal guaranteed to be returned?

No. Cost basis is an accounting measure. FairDot does not guarantee recovery of the same quote value as the holder’s cost basis. Price movement, liquidity, price impact, lack of buyers, and execution can all reduce proceeds or prevent a sale.

## Large sales and market boundaries

### Are large sales split automatically?

The target automatically creates a schedule based on estimated quote output of the **full request** (principal plus profit) divided by the pool quote reserve at schedule start:

| Estimated full-request output / quote reserve | Target schedule |
| --- | --- |
| `≤ 10%` | One part, attempted immediately |
| `> 10%` through `30%` | Three parts, 8 hours apart |
| `> 30%` | Ten parts, 24 hours apart |

The first part is attempted immediately. After a successful one-part sale at or below 10%, the same address must wait 8 hours before another sale. For larger schedules, part sizes are fixed in token units, and any rounding remainder goes to the last part. Each installment rechecks eligibility. An ineligible installment waits; the interval to the next installment begins only after a successful one. Other sales are blocked while a schedule is active. The holder may cancel remaining installments, but cooldown since the last successful installment persists. Later installments require holder transactions; no keeper is included in the target design.

A schedule is per holder, not a global queue. It does not reserve quote liquidity or guarantee execution price or payout.

### Can splitting wallets evade the rules?

Transfers carry position history, but the target does not include KYC or anti-sybil controls. The 8-hour cooldown is address-based; coordinated or separately funded wallets may still divide activity across addresses. The rules cannot ensure that multiple EOAs are one identity or prevent every form of coordination. A global sale queue is not part of v1.

### Can I trade OTC or on another chain?

The target rules govern supported interactions with the canonical pool, not OTC or other off-chain transactions. Unregistered cross-chain representations are not prevented. FairDot does not prevent price losses or rug pulls.

### Are team tokens sellable through the pool?

In target v1, team allocation follows separately published vesting and is not sellable through the pool. Gifts and airdrops do not gain recorded cost basis merely by being received.

### Can the parameters be changed after launch?

The target fixes the numeric inputs after the initial quote seed is chosen and before deployment. One canonical pool and v1 parameters are immutable after trading starts. Changing rules requires a new token/contract and voluntary migration.

## V1 limitations and project context

### What is intentionally out of scope?

V1 does not include a global queue, KYC/anti-sybil controls, LP lock, keeper, or guarantee against rug pulls. A canonical-pool rule set cannot guarantee liquidity, stable prices, successful exits, cost-basis recovery, or profit for every holder.

### What is the project context?

FairDot was developed for Portaldot Hacker House 2026 on DoraHacks, under Ecosystem DApps. That context does not imply deployment status, an audit, or investment endorsement.

## Disclaimer

FairDot is experimental software and a market-mechanics design, not financial advice. The target rules do not guarantee stable prices, liquidity, quote recovery, successful execution, or profit. Verify the repository’s actual capabilities through code review and tests; tests alone do not replace independent security review.
