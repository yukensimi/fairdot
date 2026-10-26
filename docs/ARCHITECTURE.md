# FairDot — Architecture (Testnet Prototype)

## Components

```text
EOA wallet
  ├─ buy/sell through the one configured MockLiquidityPool
  └─ wallet-to-wallet transfer inherits tracked cost basis

MockLiquidityPool (testnet only)
  ├─ calls FairDot.recordBuy and recordPrice after a buy
  ├─ calls FairDot.activateLock before validating a sell
  ├─ calls FairDot.validateWithdraw before a sell
  ├─ calls FairDot.confirmStaggerWithdraw after an installment
  └─ updates quote liquidity after each swap

FairDot token
  ├─ stores aggregate token-weighted cost basis
  ├─ compares 24-hour quote-volume VWAP with each holder's entry price
  ├─ validates protected sell amount and stagger installment
  └─ blocks token transfers involving unapproved contract addresses
```

## 1. Pool configuration

The owner deploys FairDot, deploys a pool contract, configures that pool, and enables trading. A pool must have contract bytecode. Once trading is active, the pool cannot be changed. The current implementation supports one pool only; router and multi-pool support are not implemented.

## 2. Buy flow

1. A buyer sends native tPOTv3 to the testnet pool.
2. The pool computes a constant-product output and transfers FairDot from the configured pool address to the buyer.
3. The pool records the buyer's token amount and execution price with `recordBuy`.
4. The pool records price and quote volume with `recordPrice` and updates quote liquidity.
5. `recordBuy` updates aggregate basis using `totalInvested / trackedTokens`.

Both buy and sell observations use quote-asset volume in the VWAP calculation. This is a single-pool testnet feed, not a production oracle.

## 3. Sell and protection flow

1. The pool calls `activateLock(user)`. If the holder is at or above 5× and has no active timer, the pool starts the 10-day timer. Below the trigger, this call clears stored lock state for that holder.
2. The pool calls `validateWithdraw(user, amount)`.
3. FairDot checks that the amount is within the holder's currently withdrawable amount and, if the transaction exceeds the liquidity threshold, that it matches an active installment schedule.
4. The token also checks the transfer route when `transferFrom` sends tokens to the pool.
5. On a successful sale, the pool transfers quote asset to the seller, updates price history, confirms the installment, and updates liquidity atomically.

The timer starts on activation, not automatically at the exact 5× crossing for every holder. The principal token amount is calculated from VWAP, not the actual quote proceeds of the specific swap.

## 4. Stagger schedule

The holder calls `createStaggerSchedule(totalTokenAmount)` for a specific amount. FairDot computes the required number of parts from the effective VWAP and current quote liquidity. The pool accepts only the exact installment amount and enforces the delay between subsequent installments. Token transfers are blocked while a schedule is active. The prototype does not accumulate separate small sales or withdrawal history across different EOAs, so the schedule is not a complete anti-drain guarantee.

## 5. Transfer policy (choice B)

- EOA-to-EOA transfers are allowed and split tracked investment/token basis in proportion to the amount transferred relative to the sender's pre-transfer balance.
- Transfers into or out of a contract are allowed only when the configured pool is the counterparty and caller.
- Other contract wallets, routers, bridges, and DEX pools are blocked.
- The token cannot stop private EOA-to-EOA arrangements or combine withdrawal history across wallets.

## 6. Known production gaps

This architecture does not implement LP locking, does not automatically assign a cost basis to the initial supply/treasury distributions, and uses an ever-growing price-history array. Lock behavior for multiple market cycles, transfers between different lock schedules, and additional purchases during an active schedule remains incomplete. The mock pool has no fee, production oracle/MEV protection, or safe production liquidity-management design. Independent audit and a production integration are mandatory before mainnet.
