# Low-Cost Launch Prototype: EIP-1167 Clones

## Purpose

This branch contains an isolated Hardhat experiment and a separate cloneable copy of the FairDot token, pool, and factory. OpenZeppelin EIP-1167 minimal clones are used to check whether launch-time code deployment can be reduced while preserving the current token accounting and market logic. Everything under `src/experimental` is prototype code, not production FairDot code, and must not be deployed.

Run it locally with:

```bash
npx hardhat test test/CloneLaunchSpike.test.js
npx hardhat test test/experimental/FairDotCloneFactory.test.js
npm test
```

## Local result

The first probe compared two small, purpose-built token/pool pairs. On the local Hardhat Shanghai EVM, it showed a 28.34% reduction in per-launch estimated gas, but that was not representative of FairDot's full code.

The second benchmark compared the current `FairDotFactory.createMeme` path against the experimental Factory creating clones of the full copied FairDot token and pool logic. The tests deployed both systems and measured `createMeme` with the same launch parameters. Local estimates were:

| Measurement | Existing Factory | Clone prototype |
| --- | ---: | ---: |
| One-time system deployment | 5,594,320 gas | 5,889,820 gas, including implementations, Factory, and Registry |
| Per-launch `createMeme` estimate | 4,853,733 gas | 799,582 gas |
| System deployment plus one launch | 10,448,053 gas | 6,689,402 gas |

The full-logic clone prototype reduced the local per-launch estimate by 4,054,151 gas, or approximately 83.53%. Its one-time system deployment estimate was 295,500 gas higher than the existing Factory. At the local estimates, the shared deployment cost is recovered within the first launch. This comparison is still only a Hardhat EVM result, not a Portaldot fee estimate.

Local runtime/initcode sizes were: existing Factory 24,415/25,817 bytes; clone token implementation 16,306/17,185 bytes; clone pool implementation 5,962/6,028 bytes; clone Factory 2,650/27,407 bytes. These are compiled local artifacts, not proof of acceptance by Portaldot V3. The clone Factory creates and binds its implementations in its constructor. The implementations embed that Factory address and reject initialization from anyone else. Tests confirmed the implementation lock, repeated-initialization rejection, creator ownership and Registry attribution, separate state across launches, and the actual buy → 5× protection → ten-active-day release path under a stable post-checkpoint VWAP.

The current full local Hardhat suite reports 38 passing tests, including the original direct-deployment regression suite, the small EIP-1167 probe, and four clone-specific tests.

## What this does not prove

- The small probe does not implement FairDot's accounting or market rules. The full clone prototype copies those rules, but it has not yet passed the complete clone-specific regression and security matrix.
- The clone contracts are duplicated experimental sources. They have not gone through a security audit or the complete test matrix against every clone-specific edge case.
- Local Hardhat gas is not a tPOT fee quote. It must not be converted into a Portaldot cost by multiplying by an assumed gas price.
- This does not verify EIP-1167 `delegatecall`, clone creation, or initialization behavior on Portaldot V3 / pallet-revive.
- This does not yet meet the target of at most 1 tPOT paid by an end user, including seed. Any subsidy and quote seed must be budgeted separately.

## Open accounting question

An exploratory test that let price continue rising after the protection checkpoint still showed some tokens unavailable after ten active days, even while the fresh VWAP stayed well above 5×. The copied logic fixes `checkpointProfit` at the checkpoint and calculates principal-equivalent tokens using the current price. This means later appreciation can change the principal-equivalent amount without being added to that fixed release bucket. This may be intended, but it needs a clear product decision. A passing test in `test/experimental/FairDotCloneFactory.test.js` now reproduces this current behavior; it documents the result and does not mean the behavior is approved as policy. The passing ten-day release test holds the post-checkpoint VWAP stable to isolate the release timer; it does not settle the rising-price case.

## Gate before any Portaldot deployment

First verify EIP-1167 clone creation, `delegatecall`, token metadata, storage isolation, and revert behavior on the Portaldot V3 / pallet-revive runtime with an explicitly approved low-risk technical test. Then run the full FairDot regression matrix against clone instances, add tests for clone-specific reentrancy and Registry/implementation binding, and resolve the rising-price release question. Measure actual mined receipts, deposits, and fees on Portaldot before deciding whether the user-facing 1 tPOT target needs platform subsidy. No clone prototype has been deployed to Portaldot.
