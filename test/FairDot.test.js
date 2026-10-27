const { expect } = require("chai");
const { ethers } = require("hardhat");
const S = 10n ** 18n;
const DAY = 24 * 60 * 60;

async function deployFixture({ quoteLiquidity = 100n * S, tokenLiquidity = 100000n * S, minBps = 0n, minAbs = 1n } = {}) {
  const [owner, user1, user2, user3] = await ethers.getSigners();
  const token = await (await ethers.getContractFactory("FairDot")).deploy("FairDot", "FDOT", 1_000_000_000);
  await token.waitForDeployment();
  const pool = await (await ethers.getContractFactory("MockLiquidityPool")).deploy(await token.getAddress());
  await pool.waitForDeployment();
  await token.setLiquidityPool(await pool.getAddress());
  await token.setMinVolumeParameters(minBps, minAbs);
  await token.disableMinting();
  await token.approve(await pool.getAddress(), tokenLiquidity);
  await pool.addLiquidity(tokenLiquidity, { value: quoteLiquidity });
  await token.enableTrading();
  return { owner, user1, user2, user3, token, pool };
}
async function txPrice(pool, token, signer, amount) {
  const receipt = await (await pool.connect(signer).buy(0, { value: amount })).wait();
  const parsed = receipt.logs.map(log => { try { return pool.interface.parseLog(log); } catch { return null; } })
    .find(log => log && log.name === "Swapped");
  return parsed.args;
}
async function mineAfter(seconds) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

describe("FairDot core accounting", function () {
  it("requires one deployed pool, a seed, disabled minting, and explicit pre-launch volume configuration", async function () {
    const [owner] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("FairDot")).deploy("FairDot", "FDOT", 1000);
    const pool = await (await ethers.getContractFactory("MockLiquidityPool")).deploy(await token.getAddress());
    await expect(token.enableTrading()).to.be.revertedWith("Pool not set");
    await token.setLiquidityPool(await pool.getAddress());
    await expect(token.setLiquidityPool(await pool.getAddress())).to.be.revertedWith("Pool already set");
    await token.approve(await pool.getAddress(), 100n * S);
    await pool.addLiquidity(100n * S, { value: S });
    await expect(token.enableTrading()).to.be.revertedWith("Minting not disabled");
    await token.disableMinting();
    await expect(token.enableTrading()).to.be.revertedWith("Min volume not configured");
    await token.setMinVolumeParameters(0, S / 10n);
    await token.enableTrading();
    expect(await token.tradingActive()).to.equal(true);
    expect(await token.initialQuoteSeed()).to.equal(S);
    await expect(token.setLiquidityPool(await owner.getAddress())).to.be.revertedWith("Trading already active");
  });

  it("requires the holder to checkpoint through the pool and persists it across a failed sell", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 100n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    await expect(token.connect(user1).checkpointLock(user)).to.be.revertedWith("Only approved pool");
    await pool.connect(user1).checkpointLock();
    expect((await token.lots(user, 0)).checkpointed).to.equal(true);
    expect((await token.positions(user)).lockedProfitTokens).to.be.greaterThan(0n);
    const balance = await token.balanceOf(user);
    await token.connect(user1).approve(await pool.getAddress(), balance);
    await expect(pool.connect(user1).sell(balance, 0)).to.emit(pool, "InstallmentDeferred");
    expect((await token.lots(user, 0)).checkpointed).to.equal(true);
  });

  it("auto-checkpoints an unopted holder and defers protected profit without reverting the checkpoint or schedule", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 10n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    const balance = await token.balanceOf(user);
    await token.connect(user1).approve(await pool.getAddress(), balance);
    await expect(pool.connect(user1).sell(balance, 0)).to.emit(pool, "InstallmentDeferred");
    expect((await token.lots(user, 0)).checkpointed).to.equal(true);
    const schedule = await pool.schedules(user);
    expect(schedule.totalAmount).to.equal(balance);
    expect(schedule.completed).to.equal(0n);
    expect(await token.balanceOf(user)).to.equal(balance);
  });

  it("consumes checkpoint-time principal budget monotonically instead of recycling shrunken quote basis", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 10n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    await pool.connect(user1).checkpointLock();
    const checkpointed = await token.lots(user, 0);
    const expectedSnapshot = checkpointed.quoteBasis * S / await token.getEffectivePrice();
    expect(checkpointed.principalBudget).to.equal(expectedSnapshot < checkpointed.quantity ? expectedSnapshot : checkpointed.quantity);
    const sold = checkpointed.principalBudget / 2n;
    await token.connect(user1).approve(await pool.getAddress(), sold);
    await pool.connect(user1).sell(sold, 0);
    const afterSale = await token.lots(user, 0);
    expect(afterSale.principalConsumed).to.equal(sold);
    expect(afterSale.principalBudget).to.equal(checkpointed.principalBudget);
    const [available] = await token.getWithdrawable(user);
    expect(available).to.be.at.most(afterSale.principalBudget - afterSale.principalConsumed + afterSale.releasedProfit);
  });

  it("keeps the remaining lot fully eligible after principal sales and ten active release days", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 10n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    await pool.connect(user1).checkpointLock();
    const before = await token.lots(user, 0);
    const sold = before.principalBudget / 2n;
    await token.connect(user1).approve(await pool.getAddress(), sold);
    await pool.connect(user1).sell(sold, 0);
    const afterSale = await token.lots(user, 0);
    expect(afterSale.checkpointProfit).to.equal(before.checkpointProfit);
    expect(afterSale.quantity).to.equal(before.quantity - sold);

    const stablePrice = await token.getEffectivePrice();
    const poolAddress = await pool.getAddress();
    await ethers.provider.send("hardhat_setBalance", [poolAddress, "0x1000000000000000000"]);
    await ethers.provider.send("hardhat_impersonateAccount", [poolAddress]);
    const poolSigner = await ethers.getSigner(poolAddress);
    for (let day = 0; day < 10; day++) {
      await mineAfter(DAY + 1);
      await token.connect(poolSigner).recordPrice(stablePrice, 100n * S);
    }
    await ethers.provider.send("hardhat_stopImpersonatingAccount", [poolAddress]);
    const [available, locked] = await token.getWithdrawable(user);
    expect(locked).to.equal(0n);
    expect(available).to.equal(afterSale.quantity);
  });

  it("uses actual quote paid and combines same-day purchases only in an unsealed lot", async function () {
    const { user1, user2, token, pool } = await deployFixture();
    const a = await txPrice(pool, token, user1, S);
    const b = await txPrice(pool, token, user1, 2n * S);
    const user = await user1.getAddress();
    expect(await token.getLotCount(user)).to.equal(1n);
    const lot = await token.lots(user, 0);
    expect(lot.quoteBasis).to.equal(3n * S);
    expect(lot.quantity).to.equal(a.tokenAmount + b.tokenAmount);
    await txPrice(pool, token, user2, 500n * S);
    await pool.connect(user1).checkpointLock();
    expect((await token.lots(user, 0)).checkpointed).to.equal(true);
    await txPrice(pool, token, user1, S / 100n);
    expect(await token.getLotCount(user)).to.equal(2n);
    expect((await token.lots(user, 1)).checkpointed).to.equal(false);
  });

  it("preserves a partially transferred lot's quote basis and checkpoint timer", async function () {
    const { user1, user2, user3, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 100n);
    await txPrice(pool, token, user2, 10n * S);
    await pool.connect(user1).checkpointLock();
    const u1 = await user1.getAddress();
    const u2 = await user3.getAddress();
    const before = await token.lots(u1, 0);
    const moved = before.quantity / 3n;
    await token.connect(user1).transfer(u2, moved);
    const source = await token.lots(u1, 0);
    const received = await token.lots(u2, 0);
    expect(received.quantity).to.equal(moved);
    expect(received.checkpointed).to.equal(true);
    expect(received.checkpointActiveTime).to.equal(before.checkpointActiveTime);
    expect(source.quoteBasis + received.quoteBasis).to.equal(before.quoteBasis);
    expect(source.quantity + received.quantity).to.equal(before.quantity);
  });

  it("allows EOA transfers but rejects token-contract and external pair-like contract routes", async function () {
    const { user1, user2, token, pool } = await deployFixture();
    await token.connect(user1).transfer(await user2.getAddress(), 0);
    await txPrice(pool, token, user1, S / 10n);
    const externalPair = await (await ethers.getContractFactory("MockLiquidityPool")).deploy(await token.getAddress());
    await expect(token.connect(user1).transfer(await externalPair.getAddress(), 1n)).to.be.revertedWith("Unapproved contract market");
    await expect(token.connect(user1).transfer(await token.getAddress(), 1n)).to.be.revertedWith("Unapproved contract market");
  });

  it("rejects sales of initial-supply, gifted, and mixed untracked amounts", async function () {
    const { user1, token, pool } = await deployFixture();
    await token.approve(await pool.getAddress(), S);
    await expect(pool.sell(S, 0)).to.emit(pool, "InstallmentDeferred");
    await pool.connect(user1).buy(0, { value: S });
    const tracked = (await token.positions(await user1.getAddress())).trackedTokens;
    await token.transfer(await user1.getAddress(), tracked);
    expect((await token.positions(await user1.getAddress())).trackedTokens).to.equal(tracked);
    await token.connect(user1).approve(await pool.getAddress(), tracked + 1n);
    await expect(pool.connect(user1).sell(tracked + 1n, 0)).to.emit(pool, "InstallmentDeferred");
  });

  it("activates protection at the configured rolling volume boundary", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S, minBps: 0n, minAbs: 501n * S / 100n });
    await txPrice(pool, token, user1, S / 100n);
    await txPrice(pool, token, user2, 5n * S);
    expect(await token.volumeThreshold()).to.equal(501n * S / 100n);
    expect(await token.getQuoteVolume24h()).to.be.at.least(await token.volumeThreshold());
    const user = await user1.getAddress();
    await pool.connect(user1).checkpointLock();
    expect((await token.lots(user, 0)).checkpointed).to.equal(true);
  });

  it("does not checkpoint below 5x but does checkpoint once fresh VWAP exceeds 5x", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S, minAbs: 1n });
    await txPrice(pool, token, user1, S / 10n);
    const user = await user1.getAddress();
    await pool.connect(user1).checkpointLock();
    expect((await token.lots(user, 0)).checkpointed).to.equal(false);
    await txPrice(pool, token, user2, 10n * S);
    const [, , ratio] = await token.getWithdrawable(user);
    expect(ratio).to.be.greaterThanOrEqual(50_000n);
    await pool.connect(user1).checkpointLock();
    const lot = await token.lots(user, 0);
    const [eligible, locked] = await token.getWithdrawable(user);
    expect(lot.checkpointed).to.equal(true);
    expect(locked).to.be.greaterThan(0n);
    expect(eligible).to.be.lessThan(lot.quantity);
  });

  it("releases all remaining profit below 5x and never re-locks it after a later recovery", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S, minAbs: 1n });
    await txPrice(pool, token, user1, S / 10n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    await pool.connect(user1).checkpointLock();
    const lot = await token.lots(user, 0);
    const entry = lot.quoteBasis * S / lot.quantity;
    await mineAfter(DAY + 1);
    const poolAddress = await pool.getAddress();
    await ethers.provider.send("hardhat_setBalance", [poolAddress, "0x1000000000000000000"]);
    await ethers.provider.send("hardhat_impersonateAccount", [poolAddress]);
    const poolSigner = await ethers.getSigner(poolAddress);
    await token.connect(poolSigner).recordPrice(entry * 4n, S);
    await pool.connect(user1).checkpointLock(); // persists the below-trigger release
    let [available, locked] = await token.getWithdrawable(user);
    expect(locked).to.equal(0n);
    expect(available).to.equal(lot.quantity);
    await token.connect(poolSigner).recordPrice(entry * 6n, S);
    await ethers.provider.send("hardhat_stopImpersonatingAccount", [poolAddress]);
    [available, locked] = await token.getWithdrawable(user);
    expect(locked).to.equal(0n);
    expect(available).to.equal(lot.quantity);
  });

  it("activates at exactly 5x when the fresh VWAP is set to the lot's exact boundary", async function () {
    const { user1, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S, minAbs: 1n });
    await txPrice(pool, token, user1, S / 10n);
    const user = await user1.getAddress();
    const lot = await token.lots(user, 0);
    const entry = lot.quoteBasis * S / lot.quantity;
    await mineAfter(DAY + 1);
    const poolAddress = await pool.getAddress();
    await ethers.provider.send("hardhat_setBalance", [poolAddress, "0x1000000000000000000"]);
    await ethers.provider.send("hardhat_impersonateAccount", [poolAddress]);
    const poolSigner = await ethers.getSigner(poolAddress);
    await token.connect(poolSigner).recordPrice(entry * 5n, S);
    await ethers.provider.send("hardhat_stopImpersonatingAccount", [poolAddress]);
    expect((await token.getEffectivePrice())).to.equal(entry * 5n);
    await pool.connect(user1).checkpointLock();
    expect((await token.lots(user, 0)).checkpointed).to.equal(true);
  });

  it("handles 25 separate daily lots without a hard lot cap and reports transfer gas", async function () {
    const { user1, user2, pool, token } = await deployFixture({ quoteLiquidity: 1000n * S, tokenLiquidity: 1000000n * S });
    for (let i = 0; i < 25; i++) {
      if (i > 0) await mineAfter(DAY + 1);
      await pool.connect(user1).buy(0, { value: S / 100n });
    }
    const user = await user1.getAddress();
    expect(await token.getLotCount(user)).to.equal(25n);
    const all = await token.balanceOf(user);
    const receipt = await (await token.connect(user1).transfer(await user2.getAddress(), all)).wait();
    console.log(`25-lot whole-position transfer gas: ${receipt.gasUsed.toString()}`);
    expect((await token.positions(await user2.getAddress())).trackedTokens).to.equal(all);
    expect(receipt.gasUsed).to.be.lessThan(5_000_000n);
  });

  it("releases over 10 active days and limits accrual over a stale multi-day observation gap", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 100n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    await pool.connect(user1).checkpointLock();
    const [, locked0] = await token.getWithdrawable(user);
    await mineAfter(DAY + 1);
    const [, locked1] = await token.getWithdrawable(user);
    await mineAfter(2 * DAY);
    const [, locked2] = await token.getWithdrawable(user);
    expect(locked1).to.be.lessThan(locked0);
    expect(locked2).to.equal(locked1);
  });

  it("completes the linear profit release after ten observed active days", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 100n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    await pool.connect(user1).checkpointLock();
    const stablePrice = await token.getEffectivePrice();
    const poolAddress = await pool.getAddress();
    await ethers.provider.send("hardhat_setBalance", [poolAddress, "0x1000000000000000000"]);
    await ethers.provider.send("hardhat_impersonateAccount", [poolAddress]);
    const poolSigner = await ethers.getSigner(poolAddress);
    for (let day = 0; day < 10; day++) {
      await mineAfter(DAY);
      await token.connect(poolSigner).recordPrice(stablePrice, 100n * S);
    }
    await ethers.provider.send("hardhat_stopImpersonatingAccount", [poolAddress]);
    await mineAfter(20);
    const [, locked] = await token.getWithdrawable(user);
    expect(locked).to.equal(0n);
  });

  it("locks profit from an uncheckpointed lot when stale emergency begins", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 10n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    expect((await token.lots(user, 0)).checkpointed).to.equal(false);
    await mineAfter(7 * DAY + 1);
    await pool.connect(user1).checkpointLock();
    const lot = await token.lots(user, 0);
    const [eligible, , , status] = await token.getWithdrawable(user);
    expect(lot.checkpointed).to.equal(true);
    expect(lot.principalBudget).to.be.lessThan(lot.quantity);
    expect(status).to.equal(4n);
    expect(eligible).to.be.at.most(lot.principalBudget);
    expect(eligible).to.be.at.most(lot.quantity / 10n);
  });

  it("starts stale emergency from an explicit holder transaction and applies a 10% snapshot cap", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 100n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    await pool.connect(user1).checkpointLock();
    await mineAfter(7 * DAY + 1);
    expect(await token.getEffectivePrice()).to.equal(0n);
    await pool.connect(user1).checkpointLock();
    const emergency = await token.emergencyState(user);
    expect(emergency.snapshot).to.equal((await token.positions(user)).trackedTokens);
    const [eligible, , , status] = await token.getWithdrawable(user);
    expect(status).to.equal(4n);
    expect(eligible).to.be.at.most(emergency.snapshot / 10n);
  });

  it("keeps emergency mode through its own sale observations and applies a rolling 24-hour quota", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 10n);
    const user = await user1.getAddress();
    const firstLot = await token.lots(user, 0);
    const entry = firstLot.quoteBasis * S / firstLot.quantity;
    await mineAfter(DAY + 1);
    const poolAddress = await pool.getAddress();
    await ethers.provider.send("hardhat_setBalance", [poolAddress, "0x1000000000000000000"]);
    await ethers.provider.send("hardhat_impersonateAccount", [poolAddress]);
    const poolSigner = await ethers.getSigner(poolAddress);
    await token.connect(poolSigner).recordPrice(entry * 5n, S);
    await ethers.provider.send("hardhat_stopImpersonatingAccount", [poolAddress]);
    await pool.connect(user1).checkpointLock();
    const checkpointed = await token.lots(user, 0);
    expect(checkpointed.principalBudget).to.be.greaterThan(firstLot.quantity / 10n);
    await mineAfter(7 * DAY + 1);
    await pool.connect(user1).checkpointLock();
    const [quota] = await token.getWithdrawable(user);
    const installment = quota * 6n / 10n;
    await token.connect(user1).approve(await pool.getAddress(), installment * 3n);
    await pool.connect(user1).sell(installment, 0); // starts emergency and records its own fresh pool observation
    expect((await token.emergencyState(user)).windowStart).to.be.greaterThan(0n);
    expect(await token.getEffectivePrice()).to.be.greaterThan(0n);
    await mineAfter(DAY - 60);
    await expect(pool.connect(user1).sell(installment, 0)).to.emit(pool, "InstallmentDeferred");
    expect((await token.emergencyState(user)).windowStart).to.be.greaterThan(0n);
    await mineAfter(65);
    await pool.connect(user1).sell(installment, 0); // first emergency sale has aged out of the rolling window
    expect((await token.emergencyState(user)).windowStart).to.be.greaterThan(0n);
  });

  it("clears emergency only on explicit checkpoint after a fresh external buy", async function () {
    const { user1, user2, token, pool } = await deployFixture({ quoteLiquidity: S, tokenLiquidity: 1000n * S });
    await txPrice(pool, token, user1, S / 100n);
    await txPrice(pool, token, user2, 10n * S);
    const user = await user1.getAddress();
    await pool.connect(user1).checkpointLock();
    await mineAfter(7 * DAY + 1);
    await pool.connect(user1).checkpointLock();
    expect((await token.emergencyState(user)).windowStart).to.be.greaterThan(0n);
    const small = (await token.positions(user)).trackedTokens / 1000n;
    await token.connect(user1).approve(await pool.getAddress(), small);
    await pool.connect(user1).sell(small, 0); // sale observation alone is not recovery
    await pool.connect(user1).checkpointLock();
    expect((await token.emergencyState(user)).windowStart).to.be.greaterThan(0n);
    await txPrice(pool, token, user2, S / 100n);
    await pool.connect(user1).checkpointLock();
    expect((await token.emergencyState(user)).windowStart).to.equal(0n);
  });

  it("enforces minimum outputs atomically for buys and executed sell installments", async function () {
    const { user1, pool, token } = await deployFixture();
    const buyValue = S;
    const tokenReserve0 = await pool.tokenReserve();
    const quoteReserve0 = await pool.quoteReserve();
    const buyQuote = tokenReserve0 - tokenReserve0 * quoteReserve0 / (quoteReserve0 + buyValue);
    const volume0 = await token.getQuoteVolume24h();
    await expect(pool.connect(user1).buy(buyQuote + 1n, { value: buyValue })).to.be.revertedWith("Slippage exceeded");
    expect(await pool.tokenReserve()).to.equal(tokenReserve0);
    expect(await pool.quoteReserve()).to.equal(quoteReserve0);
    expect((await token.positions(await user1.getAddress())).trackedTokens).to.equal(0n);
    expect(await token.getQuoteVolume24h()).to.equal(volume0);
    await pool.connect(user1).buy(buyQuote, { value: buyValue });
    const user = await user1.getAddress();
    const amount = (await token.positions(user)).trackedTokens / 100n;
    await token.connect(user1).approve(await pool.getAddress(), amount);
    const sellQuote = await pool.quoteSell(amount);
    const tokenReserve1 = await pool.tokenReserve();
    const quoteReserve1 = await pool.quoteReserve();
    const position1 = await token.positions(user);
    const lot1 = await token.lots(user, 0);
    await expect(pool.connect(user1).sell(amount, sellQuote + 1n)).to.be.revertedWith("Slippage exceeded");
    expect(await pool.tokenReserve()).to.equal(tokenReserve1);
    expect(await pool.quoteReserve()).to.equal(quoteReserve1);
    expect((await token.positions(user)).trackedTokens).to.equal(position1.trackedTokens);
    expect((await token.lots(user, 0)).quantity).to.equal(lot1.quantity);
  });

  it("auto-creates a 3-part schedule for a large sale, tries part one immediately, and waits between holder installments", async function () {
    const { user1, pool, token } = await deployFixture({ quoteLiquidity: 100n * S, tokenLiquidity: 100000n * S });
    await pool.connect(user1).buy(0, { value: 20n * S });
    const user = await user1.getAddress();
    const amount = 15000n * S;
    await token.connect(user1).approve(await pool.getAddress(), amount);
    await pool.connect(user1).sell(amount, 0);
    let schedule = await pool.schedules(user);
    expect(schedule.totalAmount).to.equal(amount);
    expect(schedule.parts).to.equal(3n);
    expect(schedule.completed).to.equal(1n);
    const part = amount / 3n;
    await expect(pool.connect(user1).sell(part, 0)).to.be.revertedWith("Installment not due");
    await mineAfter(8 * 60 * 60);
    await pool.connect(user1).sell(part, 0);
    schedule = await pool.schedules(user);
    expect(schedule.completed).to.equal(2n);
    await mineAfter(8 * 60 * 60);
    await pool.connect(user1).sell(amount, 0);
    expect((await pool.schedules(user)).totalAmount).to.equal(0n);
  });

  it("prevents a contract-wallet payout callback from cancelling its active sale schedule", async function () {
    const { pool } = await deployFixture({ quoteLiquidity: 100n * S, tokenLiquidity: 100000n * S });
    const seller = await (await ethers.getContractFactory("MockReentrantSeller")).deploy(await pool.getAddress());
    await seller.waitForDeployment();
    await seller.buy({ value: 20n * S });
    await seller.setCancelOnReceive(true);
    const user = await seller.getAddress();
    const amount = 15000n * S;

    await seller.sell(amount, 0);
    expect(await seller.cancelAttempted()).to.equal(true);
    const schedule = await pool.schedules(user);
    expect(schedule.totalAmount).to.equal(amount);
    expect(schedule.completed).to.equal(1n);
    expect(await pool.cooldownUntil(user)).to.be.greaterThan(0n);
    await expect(seller.sell(amount / 3n, 0)).to.be.revertedWith("Installment not due");
  });

  it("uses inclusive 10% and 30% thresholds and moves to the next schedule above each", async function () {
    const { token } = await deployFixture({ quoteLiquidity: 100n * S });
    const at10 = await token.getStaggerInfo(10n * S);
    const above10 = await token.getStaggerInfo(10n * S + 1n);
    const at30 = await token.getStaggerInfo(30n * S);
    const above30 = await token.getStaggerInfo(30n * S + 1n);
    expect(at10.parts).to.equal(1n);
    expect(above10.parts).to.equal(3n);
    expect(above10.interval).to.equal(8n * 60n * 60n);
    expect(at30.parts).to.equal(3n);
    expect(above30.parts).to.equal(10n);
    expect(above30.interval).to.equal(DAY);
  });

  it("allows cancellation but prevents cooldown bypass after the last successful installment", async function () {
    const { user1, pool, token } = await deployFixture({ quoteLiquidity: 100n * S, tokenLiquidity: 100000n * S });
    await pool.connect(user1).buy(0, { value: 20n * S });
    const amount = 15000n * S;
    await token.connect(user1).approve(await pool.getAddress(), amount);
    await pool.connect(user1).sell(amount, 0);
    await pool.connect(user1).cancelSchedule();
    expect((await pool.schedules(await user1.getAddress())).totalAmount).to.equal(0n);
    await expect(pool.connect(user1).sell(S, 0)).to.be.revertedWith("Sell cooldown active");
    await mineAfter(8 * 60 * 60);
    await expect(pool.connect(user1).sell(S, 0)).not.to.be.reverted;
  });

  it("makes zero reserve observable and avoids division-by-zero in threshold calculation", async function () {
    const token = await (await ethers.getContractFactory("FairDot")).deploy("FairDot", "FDOT", 1000);
    const pool = await (await ethers.getContractFactory("MockLiquidityPool")).deploy(await token.getAddress());
    await token.setLiquidityPool(await pool.getAddress());
    expect(await pool.getPrice()).to.equal(0n);
    expect((await token.getStaggerInfo(S))[0]).to.equal(1n);
  });

  it("allows the first one-part small sale immediately and cools down repeated small sales for eight hours", async function () {
    const { user1, pool, token } = await deployFixture({ quoteLiquidity: 100n * S, tokenLiquidity: 100000n * S });
    await pool.connect(user1).buy(0, { value: S });
    const user = await user1.getAddress();
    const amount = (await token.positions(user)).trackedTokens / 100n;
    await token.connect(user1).approve(await pool.getAddress(), amount * 2n);
    await expect(pool.connect(user1).sell(amount, 0)).not.to.be.reverted;
    expect(await pool.cooldownUntil(user)).to.be.greaterThan(0n);
    await expect(pool.connect(user1).sell(amount, 0)).to.be.revertedWith("Sell cooldown active");
    await mineAfter(8 * 60 * 60);
    await expect(pool.connect(user1).sell(amount, 0)).not.to.be.reverted;
  });

  it("records buy and sell quote volumes consistently", async function () {
    const { user1, pool, token } = await deployFixture();
    await pool.connect(user1).buy(0, { value: S });
    const amount = (await token.balanceOf(await user1.getAddress())) / 20n;
    await token.connect(user1).approve(await pool.getAddress(), amount);
    const before = await token.getQuoteVolume24h();
    await pool.connect(user1).sell(amount, 0);
    expect(await token.getQuoteVolume24h()).to.be.greaterThan(before);
  });
});
