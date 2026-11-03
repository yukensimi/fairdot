# Low-Cost Launch Spike: EIP-1167 Clones

## Purpose

This is an isolated Hardhat experiment to check whether OpenZeppelin EIP-1167 minimal clones can reduce the per-launch deployment work for a token/pool pair while preserving one-time initialization and per-instance state. It is not a production FairDot implementation and must not be deployed.

Run it locally with:

```bash
npx hardhat test test/CloneLaunchSpike.test.js
```

## Local result

The probe compared two small, purpose-built token/pool pairs with metadata, creator, supply, and seed state. On the local Hardhat Shanghai EVM, the observed estimates were:

| Measurement | Direct deployment | Clone deployment |
| --- | ---: | ---: |
| One-time factory deployment | 689,729 gas | 892,746 gas, including both implementations |
| Per-launch token/pool pair | 441,162 gas | 316,121 gas |

The clone path reduced the probe's per-launch estimate by 125,041 gas, or approximately 28.34%. Its one-time implementation overhead was 203,017 gas. At these local estimates, two launches are the first point where total factory-plus-launch gas becomes lower for the clone probe: 1,524,988 gas versus 1,572,053 gas for two direct launches.

The tests also confirmed that the clone implementation's own initializer is locked, each clone initializes once, the creator is recorded per clone, and creating a second clone does not overwrite the first clone's state.

## What this does not prove

- The probe does not implement FairDot's per-lot accounting, transfers, 5x protection, ten-day release, stale emergency, sale schedules, or canonical Registry behavior.
- The measured bytecode and initialization writes are much smaller than the real FairDot and pool. Therefore the 28.34% result is not an estimate of actual FairDot launch savings.
- Local Hardhat gas is not a tPOT fee quote. It must not be converted into a Portaldot cost by multiplying by an assumed gas price.
- This does not verify EIP-1167 `delegatecall`, clone creation, or initialization behavior on Portaldot V3 / pallet-revive.
- This does not yet meet the target of at most 1 tPOT paid by an end user, including seed. Any subsidy and quote seed must be budgeted separately.

## Gate before adapting FairDot

First verify clone and delegatecall compatibility with the Portaldot V3 runtime using a disposable, low-risk technical probe, subject to an explicit deployment decision. If that passes, create a separate clone-compatible FairDot/Pool prototype that replaces constructors and per-instance immutables with guarded initializers. Preserve the production regression suite and add tests for initializer front-running, repeated initialization, creator attribution, token/pool binding, Registry uniqueness, reentrancy, and all existing FairDot market rules. Compare deployment estimates and mined receipts on Portaldot before claiming a per-launch cost or opening token creation to users.
