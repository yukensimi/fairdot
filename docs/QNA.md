# Complete Q&A - FairDot

## A. Background

**Q: What is the main problem with today's memecoin market?**
A: When price moons, early holders dump everything at once -> price crashes in minutes. Late entrants are left holding massive losses. There's no fairness: first out wins, everyone else pays.

**Q: What change does FairDot introduce?**
A: It shifts from "first out wins" to "everyone grows together." When price moons, nobody can exit first and leave others behind - all participants share the upside.

---

## B. Core Mechanism

**Q: When does the restriction activate?**
A: It's computed against YOUR OWN entry price:
- < 5x gain -> 100% freely withdrawable
- >= 5x gain -> principal stays free, profit released 10%/day over 10 days

**Q: Is my principal ever locked?**
A: NEVER. Your principal is always fully withdrawable at any time. Only outsized profits are released gradually.

**Q: How is profit vs principal calculated?**
A: Every buy records your weighted-average entry price. When selling: the portion worth your principal is free. The portion above principal = profit -> released gradually.

**Q: How are large withdrawals prevented from crashing the market?**
A: If a withdrawal exceeds 10% of total liquidity, it's automatically split into installments (3 or 10 parts). The pool never drains in one shot.

**Q: What if price drops while some profit is still locked?**
A: The portion already released remains freely withdrawable. If price drops back below the 5x threshold, the system returns to normal mode - everything becomes free.

**Q: Can I bypass the rules by moving tokens to a new wallet?**
A: No. Entry price is inherited proportionally on transfers. You cannot reset your entry price.

---

## C. Fairness for All Parties

**Q: Do early holders lose out?**
A: Quite the opposite. Without FairDot, price crashes in minutes and early holders only profit briefly. With FairDot, price holds for days -> total profit they can realize is LARGER.

**Q: What about late entrants who buy at the top?**
A: Their principal is always free to withdraw. If price moons further, their profit is computed from THEIR entry price - the same fair ratio as early holders.

**Q: What about whales (large capital)?**
A: Whales benefit the most. Whales fear being trapped at the top when everyone else exits first. FairDot guarantees nobody can exit before them. Their profit remains intact - only the release timing is spread out to keep price stable.

**Q: Is this system anti-wealth?**
A: NO. It is anti-market-destruction. Anyone can get rich, as long as they don't crash the market while exiting.

---

## D. Security

**Q: How is rugpull prevented?**
A: Liquidity is locked, minting is permanently disabled after launch, and the project creators are subject to the same rules as everyone else.

**Q: Does the system guarantee price won't drop?**
A: NO. The system governs HOW profits are released, it does NOT guarantee price always rises. Price remains free to move with the market.

**Q: How is trigger manipulation prevented?**
A: The trigger uses the 24h volume-weighted average price, not spot price. A few minutes of spike won't activate it.

**Q: What happens if there are no more buyers?**
A: Everyone still exits gradually. Nobody gets the absolute top, but nobody gets zero either. The average outcome is far better than in a normal market where latecomers get almost nothing.

---

## E. Technical & Deployment

**Q: What network is it built on?**
A: Portaldot V3 (EVM), Chain ID 420420777. Contracts written in Solidity ^0.8.24, fully compatible with the EVM ecosystem.

**Q: Why size-optimized compiler settings?**
A: PortaldotV3 (pallet-revive) charges a storage deposit of ~0.08 tPOTv3 per byte of deployed code. Using optimizer runs=1, viaIR=true, EVM shanghai, and no metadata minimizes deployment cost.

**Q: How do I fund my EVM wallet for deployment?**
A: Use the Node Console's Developer -> Runtime calls -> `reviveApi.accountId` to map your H160 (0x...) address to its SS58 (5...) address, then send test tPOTv3 to that SS58 address. Do NOT send directly to the H160 address.

**Q: What's the deploy command?**
A: `npm run deploy:portaldotv3` (uses hardhat.config.cjs with network `portaldotv3Testnet`).

**Q: Can it integrate with DEXes like Uniswap?**
A: Yes. The contract is designed so the DEX pool calls `recordBuy`, `recordPrice`, and `validateWithdraw`. A mock pool is included for testing.

**Q: What's needed before mainnet?**
A: Integration with a real DEX, third-party security audit, and a user-facing DApp that displays each user's position.

---

## F. Conclusion

**Q: What is the core change FairDot introduces?**
A: It rewrites the memecoin market rulebook - from "the fastest exits wins" to "everyone who enters, whenever they enter, grows together."

**Q: What is the key message?**
A: "You may profit as much as you want - just don't destroy the ground everyone else stands on."
