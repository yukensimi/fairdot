# Architecture - FairDot

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     USER (DApp / Wallet)                     │
│              (MetaMask / any EVM-compatible wallet)          │
└──────────────────────────┬──────────────────────────────────┘
                           │ buy/sell transactions
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                  LIQUIDITY POOL (DEX)                        │
│  • Swaps FAIR token ↔ quote token (tPOTv3)                  │
│  • Calls recordBuy() + recordPrice() after every swap       │
│  • Calls validateWithdraw() BEFORE executing a sell         │
│  • Calls updateLiquidity() when liquidity changes          │
└──────────────────────────┬──────────────────────────────────┘
                           │ contract calls
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                FAIRDOT SMART CONTRACT                        │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ User Position│  │ Price History│  │ Stagger Schedule │  │
│  │ • avgEntry   │  │ • price[]    │  │ • large withdraw │  │
│  │ • invested   │  │ • volume[]   │  │ • parts & delay  │  │
│  │ • lockStart  │  │ • timestamp  │  │                  │  │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │
│         │                 │                    │            │
│         └─────────────────┼────────────────────┘            │
│                           ▼                                 │
│              ┌────────────────────────┐                     │
│              │   CORE LOGIC ENGINE     │                     │
│              │  • getAvgPrice24h()    │                     │
│              │  • getWithdrawable()   │                     │
│              │  • validateWithdraw()  │                     │
│              │  • activateLock()      │                     │
│              │  • _inheritPosition()  │                     │
│              └────────────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │   PORTALDOT V3 EVM     │
              │   Chain ID: 420420777  │
              │   Storage deposit:     │
              │   ~0.08 tPOTv3/byte    │
              └────────────────────────┘
```

## Deployment Optimizations (PortaldotV3-specific)

PortaldotV3 (pallet-revive) charges a storage deposit per byte of deployed code. The contract is therefore compiled with size-optimized settings:

| Setting | Value | Purpose |
|---|---|---|
| `optimizer.runs` | 1 | Minimize bytecode size |
| `viaIR` | true | Better optimization pipeline |
| `evmVersion` | shanghai | Target EVM version |
| `metadata.bytecodeHash` | none | Remove metadata hash |
| `metadata.appendCBOR` | false | Remove CBOR metadata |
| Solidity | 0.8.24 | Matches reference |

## Detailed Flow

### 1. When a user BUYS tokens
```
User -> DEX Pool: buy FAIR with quote token
DEX Pool -> FairDot.recordBuy(user, amount, price)
   -> Compute new weighted-average entry price
   -> Update totalInvested
DEX Pool -> FairDot.recordPrice(price, volume)
   -> Append point to priceHistory[]
DEX Pool -> FairDot.updateLiquidity(newTotal)
   -> Update total liquidity for stagger calculation
Tokens transferred to user
```

### 2. When a user SELLS tokens
```
User -> DEX Pool: sell FAIR
DEX Pool -> FairDot.validateWithdraw(user, amount)
   ├─ Compute effectivePrice (24h VWAP)
   ├─ Compute ratio = effectivePrice / avgEntryPrice
   ├─ If ratio < 5x -> ALLOW everything
   └─ If ratio >= 5x -> Compute:
        • capitalTokens = totalInvested / effectivePrice  (free)
        • profitTokens = remainder -> check % released by day
        • Compare amount vs withdrawableNow
        • Also check stagger rules for large withdrawals
   -> Return: allowed (true/false) + reason
If allowed -> DEX executes swap
If rejected -> transaction reverts with clear message
```

### 3. When Lock Activates (ratio crosses 5x)
```
DEX Pool detects ratio >= 5x for a user
DEX Pool -> FairDot.activateLock(user)
   -> Record lockedProfitStart = block.timestamp
   -> Record lockedProfitTokens = profit token amount
   -> Emit ProtectionActivated event
From this point, profit releases 10% per day over 10 days
```

### 4. When tokens are TRANSFERRED between wallets
```
User A -> transfer(amount) to User B
Before execution: _inheritPosition(A, B, amount)
   -> Compute proportion: share = amount / (balanceA + amount)
   -> inheritedInvested = totalInvested_A × share
   -> User B: merge position (weighted-average entry price)
   -> User A: reduce totalInvested proportionally
   -> If totalInvested_A = 0 -> reset A's position
Result: Cannot "reset" entry price by moving wallets
```

## System Parameters (Constants)

| Parameter | Value | Description |
|---|---|---|
| `RATIO_TRIGGER` | 5x | Protection activation threshold |
| `RELEASE_DAYS` | 10 days | Gradual profit release duration |
| `STAGGER_THRESHOLD_LOW` | 10% liquidity | Light stagger threshold |
| `STAGGER_THRESHOLD_HIGH` | 30% liquidity | Heavy stagger threshold |

## Security Guarantees

- ✅ **ReentrancyGuard** on state-changing functions
- ✅ **Ownable** - only owner can set pool & enable trading
- ✅ **Minting permanently disableable** - no unexpected inflation
- ✅ **Only trusted pool** can call recordBuy / recordPrice / activateLock
- ✅ **Position inheritance** prevents bypass via transfers
- ✅ **Size-optimized** - minimizes storage deposit cost on PortaldotV3
- ⚠️ **Requires third-party audit** before mainnet deployment
