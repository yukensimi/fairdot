<div align="center">
<img src="logo.PNG" alt="FairDot logo" width="132" />
  <h1>FairDot</h1>
  <p><strong>Fairer exit mechanics for memecoin markets</strong></p>
  <p>Built for <strong>Portaldot Hacker House 2026</strong> on DoraHacks · Ecosystem DApps</p>
  <p><code>Portaldot V3 EVM</code> · Chain ID <code>420420777</code> · Solidity <code>0.8.24</code></p>
</div>

---

## At a glance

FairDot explores a different set of exit rules for a memecoin market. The contract tracks each holder’s token-quantity-weighted entry cost, makes the estimated principal-equivalent token amount available under defined conditions, and releases outsized gains over time. A separate withdrawal schedule is available for larger sales relative to the pool’s quote reserve.

The current implementation is intentionally centered on one configured pool. It is a working concept and codebase for the Portaldot Hacker House, not a promise of price stability or investment returns.

> **Core idea:** “You may profit as much as you want—just don’t destroy the ground everyone else stands on.”

## Contents

- [The problem](#the-problem)

- [How FairDot works](#how-fairdot-works)

- [Project Structure](#project-structure-matches-proven-reference-layout)

- [Build and test](#build-and-test)

- [Portaldot configuration](#portaldot-configuration)

- [Deployment](#deployment)

- [Hacker House submission checklist](#hacker-house-submission-checklist)

- [Documentation](#documentation)

- [Disclaimer](#disclaimer)

## The problem

In a typical memecoin market, holders can attempt to exit at the same time. A large sale may rapidly reduce pool liquidity and move the price, leaving later sellers with a worse outcome. FairDot asks whether position-aware release rules and optional large-withdrawal schedules can make exits more deliberate.

FairDot does not remove market risk. It changes the rules applied to token sales routed through its configured pool.

## How FairDot works

### Position-aware protection

Each buy updates a holder’s tracked token amount and quote-denominated cost basis. The contract compares the holder’s average entry price with a recent pool price measure:

| Effective price ÷ holder entry price | Contract behavior |
| --- | --- |
| Below 5× | Tracked tokens are withdrawable, subject to fresh price data and pool execution. |
| At or above 5× | The token amount estimated to represent principal remains available; tracked profit tokens are released linearly over 10 days after the pool observes the first protected sell attempt. |

“Principal available” describes a token amount calculated from recorded cost basis and the effective price. It does **not** guarantee that the holder can recover a particular amount of quote currency: execution depends on pool liquidity, price impact, and market conditions. See [Concept & Formulas](docs/CONCEPT.md) for the equations and examples.

### Optional large-withdrawal schedule

A large withdrawal is not automatically split. If the amount exceeds the configured threshold, a sale without an active schedule is rejected; the holder must create a schedule for the intended token amount first.

| Value of the intended withdrawal vs. pool quote reserve | Schedule |
| --- | --- |
| Up to and including 10% | No schedule required |
| More than 10%, up to and including 30% | 3 equal installments, 8 hours apart |
| More than 30% | 10 installments, 24 hours apart |

The schedule is bound to a token quantity. Repeated small sales or distributing holdings across multiple wallets can still weaken the intended effect; see [Q&A](docs/QNA.md).

### Transfer and market policy

FairDot routes market transactions through one configured pool. Transfers between ordinary wallets are allowed and carry position accounting proportionally. Contract-address interactions are restricted; that pool is the only supported market endpoint. Initial supply, minted tokens, and other tokens without recorded buy cost are marked untracked and cannot be sold through the pool as if they had a purchase history.

## Project Structure (matches proven reference layout)

```
fairdot/
├── src/                              # Solidity sources (Foundry-style layout)
│   ├── FairDot.sol                   # ERC-20, cost basis, protection and schedules
│   └── MockLiquidityPool.sol         # Single-pool market used for evaluation
├── scripts/
│   └── deploy.cjs                    # Hardhat deployment and optional initial seed
├── test/
│   └── FairDot.test.js               # Local contract and market-flow tests
├── docs/
│   ├── CONCEPT.md                    # Product model and mathematical definitions
│   ├── ARCHITECTURE.md               # Contracts, flows and trust boundaries
│   └── QNA.md                        # Product and technical questions
├── index.html                        # Visual project page / demo interface
├── logo.PNG                          # FairDot brand asset
├── portaldot-logo.png                # Portaldot brand asset
├── animasi.mp4                       # Visual background asset
├── hardhat.config.cjs                # Solidity, EVM and Portaldot network settings
├── foundry.toml                      # Foundry configuration
├── remappings.txt                    # Foundry dependency remappings
├── package.json
├── package-lock.json
├── .env.example                      # Environment-variable template
├── .gitignore
├── LICENSE
└── README.md
```

## Build and test

Requirements: Node.js and npm. From the repository root:

```bash
npm ci
npm run compile
npm test
```

The current local suite contains **15 passing tests**. These tests cover core accounting, transfer, protection, schedule, and access-control behavior; they are not a security audit.

## Portaldot configuration

| Setting | Value |
| --- | --- |
| Network | Portaldot V3 EVM |
| Chain ID | `420420777` |
| RPC | `https://test-evm-rpc-v3.portaldot.dev` |
| Native quote asset in the included pool | `tPOTv3` |
| Solidity compiler | `0.8.24` |
| EVM target | `shanghai` |

The compiler is configured with optimizer runs set to `1`, `viaIR: true`, and Solidity metadata disabled to keep deployed code compact for this environment. Actual transaction costs and runtime deposits depend on the network state; the script’s preflight is only an estimate.

If you need to fund an EVM account, follow Portaldot’s current official instructions for mapping the H160 address to its corresponding native account. Never share or commit your private key or seed phrase.

## Deployment

1. Install dependencies and run the build and tests above.

1. Create a local environment file and add your RPC URL and private key:

   ```bash
   cp .env.example .env
   ```

   Set `PORTALDOTV3_TESTNET_RPC_URL` and `PRIVATE_KEY` in `.env`. Keep `.env` private and untracked.

1. Run a read-only deployment preflight:

   ```bash
   PREFLIGHT_ONLY=1 npm run deploy:portaldotv3
   ```

   The preflight checks the configured chain and estimates contract-deployment gas. It does not send a transaction and does not fully account for runtime deposits or every setup transaction.

1. To have the deployment script seed the pool, set **both** of these optional variables in `.env` to the intended seed amounts:

   ```
   INITIAL_LIQUIDITY_TOKEN_AMOUNT=1000000
   INITIAL_LIQUIDITY_TPOT=100
   ```

   These are examples of input format, not recommended liquidity amounts. With both values set, the live deployment sends token approval and initial-liquidity transactions, then disables minting and enables trading after confirming the seed. The quote amount is an on-chain deposit; confirm your account balance and intended parameters before running a live deployment.

1. Run the live command only when ready to submit those transactions:

   ```bash
   npm run deploy:portaldotv3
   ```

If the two initial-liquidity variables are omitted, the script deploys and configures the contracts but leaves trading disabled; it does not seed the pool, disable minting, or enable trading. Save the deployed addresses, transaction hashes, and block numbers for the submission record.

## Hacker House Submission Checklist

- [x] Public GitHub repository and project source

- [x] FairDot concept, architecture, and Q&A documentation in English

- [x] Project README with setup, deployment, and structure information

- [x] Solidity build configuration for Portaldot V3 EVM

- [x] Local compile and test run: 15 tests passing

- [ ] Deploy the reviewed build to Portaldot V3 and record token/pool addresses, transaction hashes, and block numbers

- [ ] Publish a working, clearly labelled demo experience

- [ ] Prepare the submission pitch deck and a concise product demonstration

## Documentation

- [Concept & mathematical formulas](docs/CONCEPT.md)

- [Architecture & transaction flows](docs/ARCHITECTURE.md)

- [Frequently asked questions](docs/QNA.md)

## Disclaimer

FairDot is an experimental hackathon project for evaluation on Portaldot. Its included pool is a minimal demonstration contract, not an independently audited production market. The rules do not guarantee price stability, liquidity, profit, or a successful exit; market execution can result in substantial loss. Do not use real assets or rely on this software for financial decisions. Review the code and obtain qualified security review before any use beyond the hackathon evaluation. Never share your private key or seed phrase.

## License

MIT. See [LICENSE](LICENSE).
