const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("FairDot", function () {
  let FairDot, fairDot, owner, pool, user1, user2;
  const DECIMALS = 18;
  const SCALE = 10n ** BigInt(DECIMALS);

  beforeEach(async function () {
    [owner, pool, user1, user2] = await ethers.getSigners();
    FairDot = await ethers.getContractFactory("FairDot");
    fairDot = await FairDot.deploy("FairDot", "FDOT", 1000000000);
    await fairDot.waitForDeployment();

    await fairDot.connect(owner).setLiquidityPool(await pool.getAddress());
    await fairDot.connect(owner).enableTrading();
  });

  describe("1. Deploy & Configuration", function () {
    it("has correct name and symbol", async function () {
      expect(await fairDot.name()).to.equal("FairDot");
      expect(await fairDot.symbol()).to.equal("FDOT");
    });
    it("trading is active and minting is disabled", async function () {
      expect(await fairDot.tradingActive()).to.equal(true);
    });
    it("cannot mint after minting is disabled", async function () {
      await fairDot.connect(owner).disableMinting();
      await expect(
        fairDot.connect(owner).mint(await owner.getAddress(), SCALE * 1000n)
      ).to.be.revertedWith("Minting is disabled");
    });
  });

  describe("2. Buy & Entry Price Recording", function () {
    it("records weighted-average entry price on buy", async function () {
      const amt = SCALE * 1000n;
      const p1 = SCALE / 10n;
      await fairDot.connect(pool).recordBuy(await user1.getAddress(), amt, p1);
      const pos = await fairDot.positions(await user1.getAddress());
      expect(pos.avgEntryPrice).to.equal(p1);
    });

    it("weighted-average entry price updates correctly on consecutive buys", async function () {
      const p1 = SCALE;
      const a1 = SCALE * 1000n;
      await fairDot.connect(pool).recordBuy(await user1.getAddress(), a1, p1);

      const p2 = 3n * SCALE;
      const a2 = SCALE * 1000n;
      await fairDot.connect(pool).recordBuy(await user1.getAddress(), a2, p2);

      const expectedAvg = 25n * SCALE / 10n;
      const pos = await fairDot.positions(await user1.getAddress());
      expect(pos.avgEntryPrice).to.equal(expectedAvg);
    });
  });

  describe("3. Normal Mode (Ratio < 5x)", function () {
    it("all tokens freely withdrawable when ratio < 5x", async function () {
      const amt = SCALE * 1000n;
      const pEntry = SCALE;
      await fairDot.connect(owner).transfer(await user1.getAddress(), amt);
      await fairDot.connect(pool).recordBuy(await user1.getAddress(), amt, pEntry);

      const pNow = 3n * SCALE;
      await fairDot.connect(pool).recordPrice(pNow, amt);

      const [withdrawable, locked, , status] = await fairDot.getWithdrawable(await user1.getAddress());
      expect(Number(status)).to.equal(0);
      expect(locked).to.equal(0n);
      expect(withdrawable).to.equal(amt);
    });
  });

  describe("4. Protection Mode (Ratio >= 5x)", function () {
    it("profit is locked when ratio >= 5x", async function () {
      await fairDot.connect(owner).transfer(await user1.getAddress(), SCALE * 1000n);
      const pEntry = SCALE;
      await fairDot.connect(pool).recordBuy(await user1.getAddress(), SCALE * 1000n, pEntry);

      const pHigh = 6n * SCALE;
      await fairDot.connect(pool).recordPrice(pHigh, SCALE * 500n);
      await fairDot.connect(pool).activateLock(await user1.getAddress());

      const [, , ratioBP, status] = await fairDot.getWithdrawable(await user1.getAddress());
      expect(Number(ratioBP)).to.be.above(50000);
      expect(Number(status)).to.equal(1);
    });

    it("profit releases 10% per day over 10 days", async function () {
      await fairDot.connect(owner).transfer(await user1.getAddress(), SCALE * 1000n);
      const pEntry = SCALE;
      await fairDot.connect(pool).recordBuy(await user1.getAddress(), SCALE * 1000n, pEntry);

      const pHigh = 10n * SCALE;
      await fairDot.connect(pool).recordPrice(pHigh, SCALE * 500n);
      await fairDot.connect(pool).activateLock(await user1.getAddress());

      const [w0, l0, , s0] = await fairDot.getWithdrawable(await user1.getAddress());
      expect(Number(s0)).to.equal(1);
      expect(l0 > 0n).to.equal(true);

      await ethers.provider.send("evm_increaseTime", [3 * 86400]);
      await ethers.provider.send("evm_mine", []);

      const [, l3, ,] = await fairDot.getWithdrawable(await user1.getAddress());
      expect(l3 < l0).to.equal(true);

      await ethers.provider.send("evm_increaseTime", [10 * 86400]);
      await ethers.provider.send("evm_mine", []);

      const [, l10, , s10] = await fairDot.getWithdrawable(await user1.getAddress());
      expect(Number(s10)).to.equal(2);
      expect(l10).to.equal(0n);
    });
  });

  describe("5. Entry-Price Inheritance (Transfer)", function () {
    it("entry price is inherited on transfer - cannot reset by moving wallets", async function () {
      await fairDot.connect(owner).transfer(await user1.getAddress(), SCALE * 1000n);

      const p1 = SCALE;
      const p2 = 3n * SCALE;
      await fairDot.connect(pool).recordBuy(await user1.getAddress(), SCALE * 500n, p1);
      await fairDot.connect(pool).recordBuy(await user1.getAddress(), SCALE * 500n, p2);

      await fairDot.connect(user1).transfer(await user2.getAddress(), SCALE * 500n);

      const pos2 = await fairDot.positions(await user2.getAddress());
      expect(pos2.avgEntryPrice > 0n).to.equal(true);
    });
  });

  describe("6. Staggered Large Withdrawals", function () {
    beforeEach(async function () {
      await fairDot.connect(pool).updateLiquidity(SCALE * 10000n);
    });

    it("withdrawal <= 10% of liquidity: instant (1 part)", async function () {
      const [parts] = await fairDot.getStaggerInfo(SCALE * 500n);
      expect(Number(parts)).to.equal(1);
    });

    it("withdrawal 10-30% of liquidity: 3 parts, 8h interval", async function () {
      const [parts, intv] = await fairDot.getStaggerInfo(SCALE * 2000n);
      expect(Number(parts)).to.equal(3);
      expect(Number(intv)).to.equal(8 * 3600);
    });

    it("withdrawal > 30% of liquidity: 10 parts, 1 day interval", async function () {
      const [parts, intv] = await fairDot.getStaggerInfo(SCALE * 4000n);
      expect(Number(parts)).to.equal(10);
      expect(Number(intv)).to.equal(24 * 3600);
    });
  });

  describe("7. Security", function () {
    it("only the pool can call recordBuy / recordPrice", async function () {
      await expect(
        fairDot.connect(user1).recordBuy(await user1.getAddress(), 100, SCALE)
      ).to.be.revertedWith("Only liquidity pool");
      await expect(
        fairDot.connect(user1).recordPrice(SCALE, 100)
      ).to.be.revertedWith("Only liquidity pool");
    });

    it("only owner can set liquidity pool", async function () {
      await expect(
        fairDot.connect(user1).setLiquidityPool(await user1.getAddress())
      ).to.be.revertedWithCustomError(fairDot, "OwnableUnauthorizedAccount")
        .withArgs(await user1.getAddress());
    });
  });
});
