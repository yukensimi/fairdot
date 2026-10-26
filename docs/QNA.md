# FairDot — Frequently Asked Questions

## A. Purpose and market behavior

### What problem is FairDot exploring?

In a typical memecoin pool, a large exit can reduce quote liquidity and move the price quickly. Later sellers may receive less favorable execution. FairDot explores position-aware withdrawal rules and optional installment schedules for sales routed through one configured pool.

### What changes with FairDot?

The contract records each pool-observed buy and its cost basis, then applies a holder-specific price-ratio rule. When the effective price reaches the protection threshold, tracked profit tokens are released over time. Large withdrawals can also require an explicit schedule. These mechanics change how certain exits are processed; they do not guarantee that everyone will share gains or be able to sell.

### What is the project’s key message?

> “You may profit as much as you want—just don’t destroy the ground everyone else stands on.”

This is a design goal, not a promise about market outcomes.

## B. Entry price, principal, and profit

### How is my entry price calculated?

FairDot calculates average entry price as total quote-denominated cost divided by the number of tracked tokens:

```text
AverageEntryPrice = TotalInvested / TrackedTokens
```

It is a token-quantity-weighted average. For example, 100 tokens bought at 1 quote unit and 100 tokens bought at 3 quote units produce a 2-quote-unit average entry price.

### When does the protection rule apply?

The ratio is based on the holder’s own recorded average entry price:

- Below `5×`, all tracked tokens are eligible under the normal withdrawal calculation, subject to fresh price data and pool execution.
- At or above `5×`, the amount of tracked tokens estimated to represent principal remains available; tracked profit tokens are released over ten days after a protected sell attempt starts the timer.

### Is my principal guaranteed to be recoverable?

No. The contract calculates a principal-equivalent **token amount** from recorded cost basis and the effective price. It does not guarantee a quote-currency refund. Pool depth, price impact, the effective price, and the availability of buyers all affect realized proceeds.

### How are principal-equivalent tokens and profit tokens estimated?

```text
PrincipalTokens = min(TrackedTokens, TotalInvested / EffectivePrice)
ProfitTokens = TrackedTokens − PrincipalTokens
```

The contract uses 18-decimal fixed-point scaling. Only tokens associated with a recorded buy are included in this calculation.

### What happens after the protection timer starts?

The timer starts when the configured pool observes the first protected sell attempt for a position without an active timer. Profit release increases linearly over ten days. At ten days, the currently calculated tracked profit amount is treated as released. A new buy resets the aggregate position’s lock state; a later protected sell can begin a new schedule.

### What if the price falls below the threshold?

When a fresh effective price is below `5×`, the active lock state is cleared and all tracked tokens become eligible under normal mode. A stale price is not treated as a reliable fallback: if the latest observation is older than 24 hours and there is no in-window volume, the effective price is unavailable and a normal pool sale is not eligible.

## C. Large withdrawals and transfers

### Are large withdrawals split automatically?

No. A large sale without a schedule is rejected. The holder must create a schedule for the exact token amount first:

| Withdrawal value relative to the pool quote reserve | Required schedule |
| --- | --- |
| Up to and including 10% | No schedule |
| More than 10%, up to and including 30% | 3 installments, 8 hours apart |
| More than 30% | 10 installments, 24 hours apart |

The schedule is per wallet and tied to token quantities. It does not promise a fixed quote amount or a fixed execution price for each installment.

### Can I reset my entry price by transferring tokens to a new wallet?

Ordinary wallet-to-wallet transfers carry tracked and untracked inventory and position basis proportionally. A transfer does not record a new purchase, so it is not intended to reset the entry price. However, this accounting is not a complete identity or anti-splitting system: splitting holdings among wallets can weaken per-wallet withdrawal thresholds.

### Which tokens can be sold through the pool?

Only tracked tokens with a recorded pool buy basis can be sold as a position. Initial supply, owner-minted tokens, and other inventory without recorded purchase cost are untracked and are not sellable through the pool as tracked tokens. When users buy from the pool, the pool’s untracked inventory is reduced and a new tracked position is recorded for the buyer.

### Can FairDot be traded through another DEX or router?

The current implementation supports one configured pool only. Contract-address market routes other than that pool are rejected. The implementation is therefore less composable than an unrestricted ERC-20 market; a different integration would need to preserve the accounting and withdrawal checks.

### Does the schedule guarantee the pool cannot be drained?

No. It can require installments for a single withdrawal that exceeds the configured thresholds, but repeated smaller sales or splitting positions across multiple wallets are not fully prevented. The schedule is not a global queue and does not guarantee reserve levels or price stability.

## D. Price, liquidity, and risk

### Does the 24-hour VWAP prevent price manipulation?

No. The 24-hour quote-volume-weighted average smooths the pool’s recorded observations and can reduce sensitivity to a single short-lived price point. It is not an independent oracle and cannot prevent manipulation. The configured pool supplies the prices and volumes used by the token contract.

### What happens if there are no buyers?

FairDot cannot create demand or guarantee a sale. If the pool has insufficient quote liquidity or no favorable counterparty flow, a transaction may fail or execute at a substantially different price than expected. The rules do not guarantee that every holder can exit gradually, recover principal, or avoid losses.

### Does FairDot guarantee stable or rising prices?

No. The contract governs withdrawal eligibility and timing for supported pool transactions; it does not control demand, market sentiment, token value, or the quote asset’s value.

### Does FairDot prevent a rug pull or lock liquidity?

No. The current project does not implement a liquidity-provider token lock and does not provide a general rug-pull guarantee. The owner and configured pool are important trust boundaries. Review the deployed code, pool configuration, and liquidity arrangements independently.

### What are the main implementation boundaries?

The current implementation has one mock pool, no swap fee, a pool-supplied price history that grows over time, and per-wallet schedules. Repeated small withdrawals, wallet splitting, mixed-age positions, repeated price cycles, and changes in pool reserves after schedule creation require careful evaluation. The mock pool is not a general-purpose exchange.

## E. Portaldot and development

### Which network and language does the project target?

The deployment configuration targets Portaldot V3 EVM, chain ID `420420777`. The contracts use Solidity `0.8.24` and OpenZeppelin ERC-20, ownership, and reentrancy utilities.

### Why are the compiler settings size-conscious?

The build uses optimizer runs `1`, `viaIR: true`, EVM target `shanghai`, and disables Solidity metadata output. These settings follow the project’s reference-oriented deployment configuration. Actual gas and runtime deposits depend on the network; the preflight is an estimate, not a fee guarantee.

### How do I configure and run the project?

```bash
npm ci
cp .env.example .env
npm run compile
npm test
```

Set `PORTALDOTV3_TESTNET_RPC_URL` and `PRIVATE_KEY` in your private `.env` file. Never commit the file or share the private key.

### What does the deployment preflight do?

```bash
PREFLIGHT_ONLY=1 npm run deploy:portaldotv3
```

It checks the configured chain and estimates contract-deployment gas without sending a transaction. It does not fully include runtime deposits or every setup transaction.

### How does the deployment script seed and enable trading?

Set both `INITIAL_LIQUIDITY_TOKEN_AMOUNT` and `INITIAL_LIQUIDITY_TPOT` to deliberately chosen amounts to have the script approve and seed the pool. After confirming the seed, it disables minting and enables trading. If the variables are omitted, the script deploys and configures the contracts but leaves trading disabled; it does not seed the pool or disable minting.

### How can an EVM account be funded?

Use Portaldot’s current official instructions for mapping an EVM H160 account to its corresponding native account and funding it. Confirm the mapping and destination on the network’s official interface before sending assets. Never send funds to an address based only on an unverified conversion.

### How many local tests are included?

The repository currently has 15 passing local tests. They test selected contract behaviors and do not prove the absence of bugs or replace an independent security review.

## F. Fairness and design intent

### Does FairDot favor early holders, late entrants, or whales?

The protection ratio is relative to each wallet’s recorded entry price, so the same threshold is applied to positions with different purchase prices. That does not guarantee equal outcomes: purchase timing, token amount, market liquidity, execution price, and position history still matter.

### Is FairDot anti-wealth?

No. The design does not set a cap on potential gains. It experiments with limits on the timing and size of exits routed through its configured pool.

### What should a reader take away?

FairDot is a proposal for more deliberate, position-aware exits—not a promise that nobody can sell first, that the market will remain stable, or that all participants will profit. For equations and implementation details, read [Concept & Mathematical Model](CONCEPT.md) and [Architecture & Transaction Flows](ARCHITECTURE.md).
