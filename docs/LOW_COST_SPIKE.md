# Low-Cost Launch Prototype: EIP-1167 Clones

## Purpose

This branch contains an isolated Hardhat experiment and a separate cloneable copy of the FairDot token, pool, and factory. OpenZeppelin EIP-1167 minimal clones are used to check whether launch-time code deployment can be reduced. The experimental token also implements the newly selected C policy for post-checkpoint appreciation in per-day release buckets, so its accounting is intentionally not identical to the direct-deployment production contract yet. Everything under `src/experimental` is prototype code, not production FairDot code, and must not be deployed.

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
| One-time system deployment | 5,594,320 gas | 6,973,978 gas, including implementations, Factory, and Registry |
| Per-launch `createMeme` estimate | 4,853,733 gas | 800,391 gas |
| System deployment plus one launch | 10,448,053 gas | 7,774,369 gas |

The full-logic clone prototype reduced the local per-launch estimate by 4,053,342 gas, or approximately 83.51%. Its one-time system deployment estimate was 1,379,658 gas higher than the existing Factory. Adding one launch, the local total is 2,673,684 gas lower (about 25.59%) than the direct deployment path. This comparison is still only a Hardhat EVM result, not a Portaldot fee estimate.

Local runtime/initcode sizes are: existing Factory 24,415/25,817 bytes; clone token implementation 21,313/22,192 bytes; clone pool implementation 5,962/6,028 bytes; clone Factory 2,650/32,414 bytes. The clone token runtime has 3,263 bytes of headroom under the 24,576-byte EIP-170 limit; the clone Factory initcode is below the 49,152-byte EIP-3860 limit. These are compiled local artifacts, not proof of acceptance by Portaldot V3. The clone Factory creates and binds its implementations in its constructor. The implementations embed that Factory address and reject initialization from anyone else. Tests confirmed the implementation lock, repeated-initialization rejection, creator ownership and Registry attribution, separate state across launches, the actual buy → 5× protection → ten-active-day release path, and the selected C appreciation-bucket behavior.

The current full local Hardhat suite reports 43 passing tests, including the original direct-deployment regression suite, the small EIP-1167 probe, and nine clone-specific tests. Clone coverage includes a twelve-consecutive-day rising-price stress case that checks completed-bucket compaction and bounds the active buckets at ten for that scenario.

## What this does not prove

- The small probe does not implement FairDot's accounting or market rules. The full clone prototype contains targeted regression coverage for the accounting and market rules, but still needs broader clone-specific differential, fuzz, and security review.
- The clone contracts are duplicated experimental sources. They have not gone through a security audit or the complete test matrix against every clone-specific edge case.
- Local Hardhat gas is not a tPOT fee quote. It must not be converted into a Portaldot cost by multiplying by an assumed gas price.
- This does not verify EIP-1167 `delegatecall`, clone creation, or initialization behavior on Portaldot V3 / pallet-revive.
- This does not yet meet the target of at most 1 tPOT paid by an end user, including seed. Any subsidy and quote seed must be budgeted separately.

## Appreciation release policy in the clone prototype

The clone prototype now implements the selected policy for appreciation after an initial 5× checkpoint:

- The initial checkpoint locks the profit amount recorded at that checkpoint and starts its existing ten-active-day linear release. Selling a released portion does not accelerate the timer for the remaining portion; the original schedule amount and already consumed amount are tracked separately.
- When a later **fresh** effective price exceeds the lot's prior high-water price, and the 5× trigger plus minimum 24-hour volume threshold still qualify, the reduction in principal-equivalent token quantity is recognized as new appreciation.
- New appreciation is grouped into one bucket per holder/lot per UTC day. Additional qualifying increases recognized in the same UTC day join that bucket; the bucket's timer begins at the first recognition that day. A later UTC day gets a separate bucket and its own ten-active-day linear release timer.
- Release time uses the existing observed-active-time clock, so stale gaps do not count as release days. Entering stale emergency persists eligible release earned before the stale period and freezes subsequent release until fresh data resumes.
- If a fresh price falls below 5×, the remaining base and appreciation profit is released rather than re-locked. A later recovery does not relock previously released profit; a new bucket can arise only from appreciation beyond the recorded high-water price.
- EOA transfers carry each bucket's UTC day and release progress proportionally. Sales consume principal first, then released profit from the oldest release amounts; unreleased bucket profit cannot be sold.

This is lazy, per-holder accounting: a higher qualified price is booked for a holder when that holder next checkpoints, sells, or transfers. Until that state-changing interaction, the extra profit remains unavailable rather than beginning a timer invisibly. This implementation and its tests are confined to `src/experimental`; the production FairDot contracts have not been changed.

## Gate before any Portaldot deployment

First verify EIP-1167 clone creation, `delegatecall`, token metadata, storage isolation, and revert behavior on the Portaldot V3 / pallet-revive runtime with an explicitly approved low-risk technical test. Continue with broader clone-specific differential, fuzz, and edge-case security review beyond the current targeted coverage for multi-day bucket stress, sale consumption, partial transfers, and emergency freeze. Measure actual mined receipts, deposits, and fees on Portaldot before deciding how the platform subsidy can meet the user-facing 1 tPOT target including seed. No clone prototype has been deployed to Portaldot.
