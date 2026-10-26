# FairDot - Fair & Protected Memecoin Trading Platform

> **Portaldot Hacker House 2026 | Track: Ecosystem DApps**
> Built on **Portaldot V3 (EVM)** - Chain ID: `420420777`
> Deployment config matches the proven reference setup (size-optimized, EVM shanghai, no metadata).

---

## The Problem

Today's memecoin market is broken:
- When price moons, early holders dump everything at once -> price crashes in minutes
- Late entrants are left holding the bag at massive losses
- Even whales get rekt - they buy the top, then everyone else exits first
- No fairness: **first out wins**, everyone else pays the price

## Our Solution

**FairDot** rewrites the rules:
- ✅ Your **PRINCIPAL is ALWAYS freely withdrawable** - 100% of the time
- 🔒 **Outsized profits** (>=5x above your entry price) are released **gradually - 10% per day over 10 days**
- 📊 Protection trigger uses **24h volume-weighted average price** - cannot be manipulated by momentary spikes
- 🐋 **Large withdrawals** are automatically staggered so they cannot drain liquidity
- 🔗 **Entry price is inherited** on transfers - no reset by moving to a fresh wallet

**Result:** Nobody can exit first and leave everyone else behind. Early holders, late entrants, and whales all share the upside fairly.

---

## Core Mechanism

### Protection Trigger (based on YOUR entry price)
| Price Ratio (vs your entry) | Mode | Rule |
|---|---|---|
| < 5x | ✅ Normal | 100% freely withdrawable |
| >= 5x | 🔒 Protection | Principal free; profit released 10%/day x 10 days |

### Large-Withdrawal Stagger (liquidity protection)
| Withdrawal Size vs Liquidity | Split |
|---|---|
| <= 10% | Instant |
| 10%-30% | 3 installments, 8h apart |
| > 30% | 10 installments, 1 day apart |

### Weighted-Average Entry Price (Important Note)
The entry price is computed as a **value-weighted average**, not a simple arithmetic average:

```
P_entry = Σ(Amount_i × Price_i) / Σ(Amount_i)
```

Where each buy's invested value is `Amount × Price / 10^18`.

**Example:**
- Buy 1,000 tokens @ price 1.0 -> invested value = 1,000
- Buy 1,000 tokens @ price 3.0 -> invested value = 3,000
- **Weighted-average entry = (1×1,000 + 3×1,000) / (1,000 + 1,000) = 2.5** (not 2.0)

---

## PortaldotV3 Testnet Info

| Setting | Value |
| --- | --- |
| Substrate RPC | `wss://test-node-v3.portaldot.dev` |
| EVM RPC | `https://test-evm-rpc-v3.portaldot.dev` |
| Chain ID | `420420777` |
| Native token | `tPOTv3` (14 decimals on Substrate; EVM layer scales to 18) |
| Node Console | `https://node-console.portaldot.dev/` |

**Funding EVM wallets:** Use the Node Console's Developer -> Runtime calls -> `reviveApi.accountId` to map the Portaldot wallet's H160 address to its SS58 address, then send test tPOTv3 to that SS58 address. **Do not transfer native funds directly to an H160 address.**

**Storage deposits:** PortaldotV3 (pallet-revive) charges a storage deposit of roughly 0.08 tPOTv3 per byte of deployed code. This contract is therefore size-optimized: `optimizer runs=1`, `viaIR=true`, `evmVersion=shanghai`, no metadata.

---

## Quick Start

```bash
git clone https://github.com/yukensimi/fairdot.git
cd fairdot
npm install
cp .env.example .env   # fill in your PRIVATE_KEY (0x...)
npm run compile
npm run test
npm run deploy:portaldotv3
```

To check the target chain, deployer balance, and estimated deployment costs without sending transactions, run `PREFLIGHT_ONLY=1 npm run deploy:portaldotv3` after setting `.env`.

---

## Project Structure (matches proven reference layout)

```
fairdot/
├── src/                          # Solidity sources (Foundry-style)
│   ├── FairDot.sol               # Core contract - fair release system
│   └── MockLiquidityPool.sol     # Mock DEX for testing
├── scripts/
│   └── deploy.cjs                # Deploy script (CommonJS, matches reference)
├── test/
│   └── FairDot.test.js           # Full test suite (14 tests, all passing)
├── docs/
│   ├── ARCHITECTURE.md           # Architecture diagram & flow
│   ├── CONCEPT.md                # Concept & mathematical formulas
│   └── QNA.md                    # Complete Q&A
├── hardhat.config.cjs            # Hardhat config (size-optimized for PortaldotV3)
├── foundry.toml                  # Foundry config (for local build/tests)
├── remappings.txt                # Foundry remappings
├── package.json
├── .env.example
├── .gitignore
├── LICENSE
└── README.md
```

---

## Deployment Steps

1. **Fund your EVM account:** Map your H160 address to SS58 via Node Console, send tPOTv3 to the SS58 address.
2. **Set PRIVATE_KEY** in `.env` (must belong to the PortaldotV3 wallet's H160).
3. **Compile:** `npm run compile`
4. **Test:** `npm run test` (14 tests should pass)
5. **Deploy:** `npm run deploy:portaldotv3`
6. **Record:** Contract address, deploy block, transaction hash.
7. **Configure:** Set pool address, enable trading, disable minting (done automatically by deploy script).

---

## Hacker House Submission Checklist

- [x] Complete smart contract with documentation
- [x] Public GitHub repository
- [x] Full README
- [x] Architecture diagram (see `docs/ARCHITECTURE.md`)
- [x] All 14 unit tests passing
- [x] Deployment config matches proven reference (size-optimized)
- [ ] Deploy to Portaldot testnet + record contract address & tx hash
- [ ] Demo (<=3 min video or live DApp link)
- [ ] Pitch deck (PDF) - problem, why Portaldot, proof of functionality, future plans

---

## Disclaimer

- This system governs **how profits are released**, it does **NOT** guarantee price will always rise
- Memecoins remain high-risk assets - DYOR
- This code is for hackathon / testnet purposes; requires third-party security audit before mainnet
- Never share your seed phrase or private key with anyone

## License

MIT - see `LICENSE`.

## Team

Built for **Portaldot Hacker House 2026** on DoraHacks.
