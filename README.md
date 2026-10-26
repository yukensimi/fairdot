# FairDot — Testnet Prototype

FairDot is an experimental ERC-20 prototype for testing holder-specific cost basis, a 5× profit-protection trigger, gradual release, and pool-integrated withdrawal limits. The current branch is intended for **local testing and Portaldot testnet only**. It is not audited and is not ready for mainnet or real-value use.

## Current rules implemented

- A holder's average entry price is the **token-amount-weighted cost basis**: total quote value invested divided by tracked token amount. Two equal buys of 1,000 tokens at prices 1 and 3 produce an average entry price of 2.
- The protection trigger compares the holder's entry price with a 24-hour volume-weighted average price (VWAP).
- At a ratio below 5×, the holder's full balance is reported withdrawable. At or above 5×, principal tokens are calculated using the same effective VWAP; profit is released linearly over 10 days after the lock is activated.
- The lock can be activated permissionlessly, and the configured pool starts it before a protected sell. A position's timer starts on activation, not automatically at the exact price crossing.
- The contract accepts contract-address token flows only through the single configured pool. Wallet-to-wallet transfers between EOAs remain possible and transfer cost basis proportionally. Unapproved contract wallets, routers, and DEX pools are blocked.
- An individual withdrawal worth more than 10% of current quote liquidity needs a schedule. The schedule is bound to a token amount and enforces 3 or 10 installments with the configured intervals. Transfers are blocked while a schedule is active.
- Initial-supply/treasury tokens have no purchase cost basis and are not sellable through the pool until a legitimate buy records a position. The first liquidity seed is a separate owner-only operation and can happen only once.

These rules are a prototype, not a guarantee that a holder can always recover principal at the price received on sale. The principal calculation uses VWAP, while actual execution price can differ because of slippage and market movement.

## Important limitations before mainnet

The current implementation has one configured pool, not a production DEX integration. Repeated small sells or splitting holdings among several EOAs can still evade a per-account, per-withdrawal stagger threshold. Wallet-to-wallet transfers preserve basis but do not combine withdrawal history across wallets. The initial supply and wallets that receive untracked tokens do not automatically receive a purchase cost basis and cannot sell those untracked tokens through the pool. Price history is stored in an ever-growing array, so its 24-hour scan is not yet bounded for high-volume production use. Lock behavior around repeated price cycles, transfers into positions with different lock times, and new buys during a lock needs additional specification and testing. No LP-lock mechanism is implemented.

The included `MockLiquidityPool` is a simple testnet constant-product pool using native tPOTv3 as quote asset. It has no swap fee, production oracle/MEV protections, or robust liquidity-management controls. Do not use it as a mainnet DEX. A formal audit and a production pool integration are required before any real-value deployment.

## Portaldot V3 testnet

| Setting | Value |
| --- | --- |
| EVM RPC | `https://test-evm-rpc-v3.portaldot.dev` |
| Chain ID | `420420777` |
| Native quote asset | `tPOTv3` |
| Node Console | `https://node-console.portaldot.dev/` |

For the EVM account's native balance, map its H160 address to the corresponding SS58 account using the Portaldot Node Console and fund that account as documented by Portaldot. Never share a private key or seed phrase.

## Local setup

```bash
git clone --branch fix/fairdot-concept-accounting https://github.com/yukensimi/fairdot.git
cd fairdot
npm ci
npm run compile
npm test
```

For the deployed branch, the deploy script checks chain ID, balance, and estimated deployment costs. On the configured testnet, run a no-transaction check with:

```bash
PREFLIGHT_ONLY=1 npm run deploy:portaldotv3
```

To seed liquidity during deployment, set **both** `INITIAL_LIQUIDITY_TOKEN_AMOUNT` and `INITIAL_LIQUIDITY_TPOT` in your local `.env`. For example, these are human-readable amounts, not secrets:

```env
INITIAL_LIQUIDITY_TOKEN_AMOUNT=1000000
INITIAL_LIQUIDITY_TPOT=100
```

With both values set, deployment sends an approval and initial-liquidity transaction, then disables minting and enables trading. These are real on-chain actions. If neither value is set, the script leaves trading disabled. The pool accepts an initial seed only once; verify the amounts and fund the wallet before running the live command.

The preflight estimates contract deployment gas only. It cannot guarantee acceptance or include all runtime-specific storage/deposit charges and subsequent setup transactions. Do not run a real deployment until the source branch and its risks have been reviewed.

## Project files

- `src/FairDot.sol` — token, cost-basis accounting, approved-pool route, lock, and stagger validation.
- `src/MockLiquidityPool.sol` — testnet-only constant-product pool.
- `scripts/deploy.cjs` — Hardhat deployment and preflight.
- `test/FairDot.test.js` — local integration tests.
- `docs/CONCEPT.md` — formulas and scope.
- `docs/ARCHITECTURE.md` — call flow and known trust assumptions.
- `docs/QNA.md` — user-facing behavior and mainnet prerequisites.

## Mainnet prerequisites

Before mainnet, define and test the remaining tokenomics and bypass cases, replace the mock with an audited pool integration, bound the price-history computation, define cost basis for initial/treasury distributions, decide how lock schedules behave across multiple market cycles and mixed positions, and obtain an independent smart-contract audit. The current 15 local tests are not a security audit.
