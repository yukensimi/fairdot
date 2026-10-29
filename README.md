<div align="center">
  <img src="logo.PNG" alt="FairDot logo" width="132" />
  <h1>FairDot</h1>
  <p><strong>Transparent exit rules for memecoin markets</strong></p>
  <p>Built for <strong>Portaldot Hacker House 2026</strong> on DoraHacks · Ecosystem DApps</p>
</div>

---

> **Positioning**
> FairDot is designed to make memecoin exit rules more transparent and reduce the impact of large sell orders through one configured pool. It does not guarantee stable prices, recovery of the same quote value as a holder’s cost basis, or profit for every holder.

## What FairDot is

FairDot is intended as a reusable on-chain protocol, not a single meme token or website. The Factory creates a token and its canonical pool for each launch; the Registry publishes that pairing. Independent platforms can discover the same Registry entry and interact with the same token and pool. Platform identity itself cannot be enforced on-chain: any interface calling a canonical pool encounters its rules.

## Target rules

- **Per-lot entry accounting:** Entry is the quote actually paid divided by tracked tokens received. Consecutive same-day buys can merge only into the holder’s latest open purchase lot; checkpointed lots and transferred lots remain separate. Transfers carry or split basis and timer without merging different timers. Sales use FIFO, oldest eligible lot first.
- **Volume-qualified profit protection:** The 24-hour quote VWAP qualifies for protection only after volume reaches `max(configured percentage × initial quote seed, configured absolute quote volume)`. The numeric inputs must be chosen after the seed is known and before launch. Before the volume threshold is met, tracked tokens are not profit-locked but remain subject to the large-sale schedule.
- **Checkpoint and release:** At or above 5× lot entry after the volume threshold is met, a holder can call `pool.checkpointLock()` to start the release timer. A sell attempt also checkpoints before eligibility is evaluated, so skipping the checkpoint button cannot bypass a qualified profit lock. An ineligible sale is deferred without reverting the checkpoint. Profit is designed to release linearly at 10% per day over 10 days. A fresh price below 5× releases remaining profit when observed through a state-changing holder action; already released profit does not re-lock.
- **Inactivity safeguards:** With no trade for more than 24 hours, the release clock pauses. After more than 7 days, `STALE_EMERGENCY_MODE` checkpoints any still-open lots against the last valid price, keeps profit locked, and uses that price explicitly for principal calculations. Eligible withdrawals are capped at 10% of the tracked-balance snapshot at emergency entry per rolling 24 hours; unused quota does not accrue. Eligibility is not a guaranteed payout.
- **Automatic large-sale installments:** The pool estimates the quote output of the full request—including principal and profit—relative to its quote reserve at schedule start. At up to 10%, the first one-part sale is attempted immediately; after it succeeds, that holder waits 8 hours before another sale. Above 10% through 30%, sales use three parts 8 hours apart; above 30%, ten parts 24 hours apart. Installments have fixed token amounts and recheck eligibility. An ineligible part waits; the next interval begins after a successful installment. Other sales are blocked while a schedule is active. A holder may cancel the remainder, but cooldown since the last successful installment persists. Later installments require holder transactions; there is no keeper.

A single canonical pool and launch parameters are fixed after trading starts. Updating the rules requires a new token/contract and voluntary migration. Gifts and airdrops do not gain purchase cost basis; the initial creator allocation is untracked and is not sellable through the pool.

## Boundaries and non-goals

The supported market path is the token’s canonical pool; external AMM pool/router contract routes are rejected by the token. EOA-to-EOA transfers remain allowed and retain their lot accounting. FairDot does not prevent OTC or other off-chain trades, price losses, unregistered cross-chain representations, or rug pulls. V1 has no global queue, KYC/anti-sybil controls, LP lock, or keeper. Pool-reported price and volume are not an independent, manipulation-proof oracle. The rules do not guarantee liquidity, execution, recovery of quote cost basis, or profit.

## Repository and verification

```bash
npm ci
npm run compile
npm test
```

The local suite exercises per-lot accounting, transfers, protection, stale behavior, sale schedules, Factory/Registry creation, and shared-pool access by independent clients. Passing tests are not a security audit.

## Project Structure (matches proven reference layout)

```text
fairdot/
├── src/
│   ├── FairDot.sol                 # ERC-20 accounting, protection, route guard
│   ├── FairDotPool.sol             # Canonical pool, buys, sells, checkpoints, schedules
│   ├── FairDotFactory.sol          # Factory and shared token/pool Registry
│   ├── MockLiquidityPool.sol       # Backward-compatible test fixture alias
│   └── test/MockReentrantSeller.sol # Test-only contract-wallet callback fixture
├── scripts/
│   ├── deploy.cjs                  # Factory deploy and fee preflight
│   └── createMeme.cjs              # Launch a token/pool via the shared Factory
├── test/
│   ├── FairDot.test.js             # Core accounting and market-rule tests
│   └── FairDotFactory.test.js      # Factory, Registry and cross-platform tests
├── docs/
│   ├── ARCHITECTURE.md             # Component model and transaction flows
│   ├── CONCEPT.md                  # Product rules and mathematical model
│   └── QNA.md                      # Product and protocol Q&A
├── index.html                     # Static presentation/dashboard mock-up; not wallet-integrated
├── hardhat.config.cjs              # Solidity and Portaldot V3 EVM configuration
├── foundry.toml                    # Foundry configuration
├── remappings.txt                  # Foundry remappings
├── package.json
├── .env.example
├── .gitignore
├── LICENSE
└── README.md
```

## Portaldot V3 launch workflow

A deployment has two separate stages. The shared Factory/Registry should be deployed once by the ecosystem operator; each compatible platform must use that same Factory address. A creator then creates a token and pool through the Factory. These scripts do not run automatically as part of the local test suite.

1. Install dependencies and configure a local environment file:

   ```bash
   npm ci
   cp .env.example .env
   ```

   Set `PORTALDOTV3_TESTNET_RPC_URL` and the EVM `PRIVATE_KEY` in `.env`. Never commit a real private key. The signing account must be funded through its mapped Portaldot SS58 account.

2. Deploy the shared Factory only after reviewing the address, gas estimate, and funding. First run a read-only gas preflight:

   ```bash
   PREFLIGHT_ONLY=1 npm run deploy:portaldotv3
   ```

   If the preflight is satisfactory, run the deployment command and record the Factory address, Registry address, transaction hash, and block. This sends an on-chain transaction.

3. Put the verified Factory address into `FAIRDOT_FACTORY_ADDRESS`. Choose the token supply, token seed, native quote seed, and both minimum-volume inputs. The minimum volume is the greater of the configured percentage of the initial quote seed and the absolute quote amount. Values are intentionally not prescribed here.

4. Run the token-creation preflight before sending a launch transaction:

   ```bash
   PREFLIGHT_ONLY=1 npm run create:meme:portaldotv3
   ```

   Review the creator, Factory/Registry address, token parameters, quote seed, gas estimate, and total required balance. Then run `npm run create:meme:portaldotv3` only when ready to launch. Record the emitted token/pool addresses and transaction hash.

A successful launch through the same shared Factory is what lets independent platform interfaces discover the same token/pool pair. Deploying separate Factory/Registry instances does not automatically make their token lists interoperable.

## Hacker House Submission Checklist

- [x] Public GitHub repository with source and license.
- [x] English concept, architecture, and Q&A documents aligned to the stated product position.
- [x] Factory/Registry and local tests for a shared canonical token/pool pairing.
- [x] Local compile and automated tests run for the current branch.
- [ ] Complete a fresh code review and security-focused test pass after final changes.
- [ ] Run Portaldot V3 Factory deployment preflight with the intended operator account.
- [ ] Deploy the shared Factory/Registry and record verified addresses, transaction hash, and block.
- [ ] Finalize seed and minimum-volume values, launch one or more example tokens, and record on-chain evidence.
- [ ] Connect the static dashboard to the deployed Factory/Registry and validate wallet flows; the current `index.html` is a mock-up, not a live trading interface.
- [ ] Prepare and link a concise project demo and any required submission materials on DoraHacks.

## Disclaimer

FairDot is experimental software and a market-mechanics design, not financial advice. Its rules do not guarantee stable prices, recovery of cost basis in quote currency, liquidity, successful execution, or profit. Holders can lose some or all of the value they put at risk. Code review and passing tests do not replace independent security review.
