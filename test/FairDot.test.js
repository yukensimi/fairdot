const { expect } = require("chai");
const { ethers } = require("hardhat");

const SCALE = 10n ** 18n;

async function deployFixture({ quoteLiquidity = 100n * SCALE, tokenLiquidity = 100000n * SCALE } = {}) {
  const [owner, user1, user2, other] = await ethers.getSigners();
  const token = await (await ethers.getContractFactory("FairDot")).deploy("FairDot", "FDOT", 1_000_000_000);
  await token.waitForDeployment();
  const pool = await (await ethers.getContractFactory("MockLiquidityPool")).deploy(await token.getAddress());
  await pool.waitForDeployment();

  await token.connect(owner).setLiquidityPool(await pool.getAddress());
  await token.connect(owner).disableMinting();
  await token.connect(owner).approve(await pool.getAddress(), tokenLiquidity);
  await pool.connect(owner).addLiquidity(tokenLiquidity, { value: quoteLiquidity });
  await token.connect(owner).enableTrading();

  return { owner, user1, user2, other, token, pool };
}

async function swapEvent(contract, txPromise, eventName = "Swapped") {
  const receipt = await (await txPromise).wait();
  for (const log of receipt.logs) {
    try {
      const parsed = contract.interface.parseLog(log);
      if (parsed && parsed.name === eventName) return parsed;
    } catch (_) {}
  }
  throw new Error(`${eventName} event not found`);
}

describe("FairDot", function () {
  describe("configuration and approved market", function () {
    it("requires a deployed pool before trading and disables minting", async function () {
      const [owner] = await ethers.getSigners();
      const token = await (await ethers.getContractFactory("FairDot")).deploy("FairDot", "FDOT", 1000);
      await token.waitForDeployment();
      await expect(token.connect(owner).enableTrading()).to.be.revertedWith("Pool not set");

      const pool = await (await ethers.getContractFactory("MockLiquidityPool")).deploy(await token.getAddress());
      await token.connect(owner).setLiquidityPool(await pool.getAddress());
      await expect(token.connect(owner).transfer(await pool.getAddress(), 1n))
        .to.be.revertedWith("Only approved pool may move pool tokens");
      await expect(token.connect(owner).enableTrading()).to.be.revertedWith("Initial liquidity not set");
      const seed = 100n * SCALE;
      await token.connect(owner).approve(await pool.getAddress(), seed);
      await pool.connect(owner).addLiquidity(seed, { value: SCALE });
      await expect(token.connect(owner).enableTrading()).to.be.revertedWith("Minting not disabled");
      await token.connect(owner).disableMinting();
      await token.connect(owner).enableTrading();
      expect(await token.tradingActive()).to.equal(true);
      expect(await token.mintDisabled()).to.equal(true);
      await expect(token.connect(owner).mint(await owner.getAddress(), 1)).to.be.revertedWith("Minting is disabled");
      await expect(token.connect(owner).setLiquidityPool(await owner.getAddress())).to.be.revertedWith("Trading already active");
    });

    it("blocks unapproved contract endpoints but permits wallet-to-wallet transfers", async function () {
      const { user1, user2, token, pool } = await deployFixture();
      const buy = await swapEvent(pool, pool.connect(user1).buy({ value: SCALE }));
      const amount = buy.args.tokenAmount / 4n;
      await expect(token.connect(user1).transfer(await token.getAddress(), amount))
        .to.be.revertedWith("Unapproved contract market");
      await expect(token.connect(user1).transfer(await pool.getAddress(), amount))
        .to.be.revertedWith("Only approved pool may move pool tokens");
      await expect(token.connect(user1).transfer(await user2.getAddress(), amount)).not.to.be.reverted;
    });

    it("does not allow untracked initial-supply tokens to be sold", async function () {
      const { owner, pool, token } = await deployFixture();
      const amount = SCALE;
      await token.connect(owner).approve(await pool.getAddress(), amount);
      await expect(pool.connect(owner).sell(amount)).to.be.revertedWith("Withdrawal not allowed");
      const [withdrawable, , , status] = await token.getWithdrawable(await owner.getAddress());
      expect(withdrawable).to.equal(0n);
      expect(status).to.equal(3n);
    });

    it("does not let gifted untracked tokens increase a buyer's sellable amount", async function () {
      const { owner, user1, pool, token } = await deployFixture();
      await pool.connect(user1).buy({ value: SCALE });
      const user = await user1.getAddress();
      const tracked = (await token.positions(user)).trackedTokens;
      await token.connect(owner).transfer(user, tracked * 2n);
      const [withdrawable] = await token.getWithdrawable(user);
      expect(withdrawable).to.equal(tracked);

      const excessive = tracked + 1n;
      await token.connect(user1).approve(await pool.getAddress(), excessive);
      await expect(pool.connect(user1).sell(excessive)).to.be.revertedWith("Withdrawal not allowed");
    });
  });

  describe("entry cost basis", function () {
    it("uses token-amount-weighted average price, not investment-value weighting", async function () {
      const { user1, pool, token } = await deployFixture();
      const first = await swapEvent(pool, pool.connect(user1).buy({ value: SCALE }));
      const second = await swapEvent(pool, pool.connect(user1).buy({ value: 3n * SCALE }));

      const tokenAmount1 = first.args.tokenAmount;
      const tokenAmount2 = second.args.tokenAmount;
      const price1 = first.args.price;
      const price2 = second.args.price;
      const invested1 = (tokenAmount1 * price1) / SCALE;
      const invested2 = (tokenAmount2 * price2) / SCALE;
      const expected = ((invested1 + invested2) * SCALE) / (tokenAmount1 + tokenAmount2);
      const oldValueWeighted = ((price1 * invested1) + (price2 * invested2)) / (invested1 + invested2);
      const position = await token.positions(await user1.getAddress());

      expect(position.totalInvested).to.equal(invested1 + invested2);
      expect(position.trackedTokens).to.equal(tokenAmount1 + tokenAmount2);
      expect(position.avgEntryPrice).to.equal(expected);
      expect(position.avgEntryPrice).not.to.equal(oldValueWeighted);
    });

    it("splits cost basis proportionally on wallet transfer and clears the sender after a full transfer", async function () {
      const { user1, user2, pool, token } = await deployFixture();
      await pool.connect(user1).buy({ value: SCALE });
      const user1Address = await user1.getAddress();
      const user2Address = await user2.getAddress();
      const initial = await token.positions(user1Address);
      const balance = await token.balanceOf(user1Address);
      const half = balance / 2n;

      await token.connect(user1).transfer(user2Address, half);
      const firstHalf = await token.positions(user1Address);
      const receiverHalf = await token.positions(user2Address);
      expect(firstHalf.totalInvested + receiverHalf.totalInvested).to.equal(initial.totalInvested);
      expect(firstHalf.trackedTokens + receiverHalf.trackedTokens).to.equal(initial.trackedTokens);
      expect(receiverHalf.avgEntryPrice).to.equal(initial.avgEntryPrice);

      const rest = await token.balanceOf(user1Address);
      await token.connect(user1).transfer(user2Address, rest);
      const cleared = await token.positions(user1Address);
      const receiverFinal = await token.positions(user2Address);
      expect(cleared.trackedTokens).to.equal(0n);
      expect(cleared.totalInvested).to.equal(0n);
      expect(receiverFinal.trackedTokens).to.equal(initial.trackedTokens);
      expect(receiverFinal.totalInvested).to.equal(initial.totalInvested);
    });

    it("removes the seller's cost basis when the approved pool buys tokens back", async function () {
      const { user1, pool, token } = await deployFixture();
      await pool.connect(user1).buy({ value: SCALE });
      const address = await user1.getAddress();
      const before = await token.positions(address);
      const sellAmount = (await token.balanceOf(address)) / 10n;
      await token.connect(user1).approve(await pool.getAddress(), sellAmount);
      await pool.connect(user1).sell(sellAmount);
      const after = await token.positions(address);
      expect(after.trackedTokens).to.be.lessThan(before.trackedTokens);
      expect(after.totalInvested).to.be.lessThan(before.totalInvested);
      const entryPriceDelta = after.avgEntryPrice > before.avgEntryPrice
        ? after.avgEntryPrice - before.avgEntryPrice
        : before.avgEntryPrice - after.avgEntryPrice;
      expect(entryPriceDelta).to.be.at.most(1n);
    });
  });

  describe("protection and price data", function () {
    it("makes a holder's lock timer start when a protected sell is attempted", async function () {
      const { user1, user2, pool, token } = await deployFixture({
        quoteLiquidity: SCALE,
        tokenLiquidity: 1000n * SCALE,
      });
      await pool.connect(user1).buy({ value: SCALE / 100n });
      await pool.connect(user2).buy({ value: 10n * SCALE });

      const address = await user1.getAddress();
      const before = await token.getWithdrawable(address);
      expect(before.status).to.equal(1n);
      expect(before.withdrawableNow).to.be.lessThan(await token.balanceOf(address));

      const sellAmount = before.withdrawableNow / 2n;
      await token.connect(user1).approve(await pool.getAddress(), sellAmount);
      await pool.connect(user1).sell(sellAmount);
      const position = await token.positions(address);
      expect(position.lockedProfitStart).to.be.greaterThan(0n);
      expect(position.lockedProfitTokens).to.be.greaterThan(0n);
    });

    it("releases 10% per day and completes at day 10 while price observations remain fresh", async function () {
      const { user1, user2, pool, token } = await deployFixture({
        quoteLiquidity: SCALE,
        tokenLiquidity: 1000n * SCALE,
      });
      await pool.connect(user1).buy({ value: SCALE / 100n });
      await pool.connect(user2).buy({ value: 10n * SCALE });
      const address = await user1.getAddress();
      await token.connect(user2).activateLock(address);

      const [, locked0] = await token.getWithdrawable(address);
      expect(locked0).to.be.greaterThan(0n);
      for (let day = 1; day <= 10; day++) {
        await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
        await pool.connect(user2).buy({ value: SCALE / 100000n });
        const [, locked] = await token.getWithdrawable(address);
        if (day < 10) expect(locked).to.be.lessThan(locked0);
        else expect(locked).to.equal(0n);
      }
    });

    it("does not let gifted untracked tokens accelerate the protected-profit release", async function () {
      const { owner, user1, user2, pool, token } = await deployFixture({
        quoteLiquidity: SCALE,
        tokenLiquidity: 1000n * SCALE,
      });
      await pool.connect(user1).buy({ value: SCALE / 100n });
      await pool.connect(user2).buy({ value: 10n * SCALE });
      const user = await user1.getAddress();
      await token.connect(user2).activateLock(user);
      const [, lockedAtStart] = await token.getWithdrawable(user);
      const tracked = (await token.positions(user)).trackedTokens;
      await token.connect(owner).transfer(user, tracked * 10n);

      await ethers.provider.send("evm_increaseTime", [24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      await pool.connect(user2).buy({ value: SCALE / 100000n });
      const [, lockedAfterOneDay] = await token.getWithdrawable(user);
      expect(lockedAtStart).to.be.greaterThan(0n);
      expect(lockedAfterOneDay).to.be.greaterThan(0n);
      expect(lockedAfterOneDay).to.be.lessThan(tracked);
    });

    it("does not fall back to a stale price after 24 hours", async function () {
      const { user1, pool, token } = await deployFixture();
      await pool.connect(user1).buy({ value: SCALE });
      await ethers.provider.send("evm_increaseTime", [24 * 60 * 60 + 1]);
      await ethers.provider.send("evm_mine", []);
      expect(await token.getEffectivePrice()).to.equal(0n);
      const [withdrawable, , , status] = await token.getWithdrawable(await user1.getAddress());
      expect(withdrawable).to.equal(0n);
      expect(status).to.equal(3n);
    });

    it("records buy and sell VWAP volume in the same quote-asset units", async function () {
      const { user1, pool, token } = await deployFixture();
      await pool.connect(user1).buy({ value: SCALE });
      const amount = (await token.balanceOf(await user1.getAddress())) / 10n;
      await token.connect(user1).approve(await pool.getAddress(), amount);
      const sale = await swapEvent(pool, pool.connect(user1).sell(amount));
      const last = await token.priceHistory(1);
      expect(last.quoteVolume).to.equal(sale.args.quoteAmount);
    });
  });

  describe("staggered withdrawals", function () {
    it("rejects a large withdrawal without a schedule and enforces installments and cooldowns", async function () {
      const { user1, user2, pool, token } = await deployFixture({
        quoteLiquidity: 100n * SCALE,
        tokenLiquidity: 1000n * SCALE,
      });
      await pool.connect(user1).buy({ value: 50n * SCALE });
      const seller = await user1.getAddress();
      const scheduleAmount = 120n * SCALE;
      await token.connect(user1).approve(await pool.getAddress(), scheduleAmount);
      await expect(pool.connect(user1).sell(scheduleAmount)).to.be.revertedWith("Withdrawal not allowed");

      await token.connect(user1).createStaggerSchedule(scheduleAmount);
      await expect(token.connect(user1).transfer(await user2.getAddress(), SCALE))
        .to.be.revertedWith("Stagger schedule active");
      const part = scheduleAmount / 3n;
      await pool.connect(user1).sell(part); // first part is immediate
      await expect(pool.connect(user1).sell(part)).to.be.revertedWith("Withdrawal not allowed");

      await ethers.provider.send("evm_increaseTime", [8 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      await pool.connect(user1).sell(part);

      await ethers.provider.send("evm_increaseTime", [8 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      const finalPart = scheduleAmount - (2n * part);
      await pool.connect(user1).sell(finalPart);
      const schedule = await token.staggerSchedules(seller);
      expect(schedule.totalAmount).to.equal(0n);
    });

    it("uses the documented thresholds", async function () {
      const { token } = await deployFixture({ quoteLiquidity: 100n * SCALE });
      const [smallParts] = await token.getStaggerInfo(5n * SCALE);
      const [mediumParts, mediumInterval] = await token.getStaggerInfo(20n * SCALE);
      const [largeParts, largeInterval] = await token.getStaggerInfo(40n * SCALE);
      expect(smallParts).to.equal(1n);
      expect(mediumParts).to.equal(3n);
      expect(mediumInterval).to.equal(8n * 60n * 60n);
      expect(largeParts).to.equal(10n);
      expect(largeInterval).to.equal(24n * 60n * 60n);
    });
  });

  describe("access control", function () {
    it("allows only the configured pool to record buys and price points", async function () {
      const { user1, token } = await deployFixture();
      await expect(token.connect(user1).recordBuy(await user1.getAddress(), SCALE, SCALE))
        .to.be.revertedWith("Only approved pool");
      await expect(token.connect(user1).recordPrice(SCALE, SCALE))
        .to.be.revertedWith("Only approved pool");
    });
  });
});
