const { expect } = require("chai");
const { ethers } = require("hardhat");

const S = 10n ** 18n;

describe("FairDot Factory and shared Registry", function () {
  async function deployFactory() {
    const factory = await (await ethers.getContractFactory("FairDotFactory")).deploy();
    await factory.waitForDeployment();
    const registry = await ethers.getContractAt("FairDotRegistry", await factory.registry());
    return { factory, registry };
  }

  async function create(factory, creator, name = "Fair Meme", symbol = "FMEME") {
    const receipt = await (await factory.connect(creator).createMeme(
      name,
      symbol,
      1_000_000,
      500_000,
      500,
      2n * S,
      { value: 10n * S }
    )).wait();
    const parsed = receipt.logs
      .map(log => { try { return factory.interface.parseLog(log); } catch { return null; } })
      .find(log => log && log.name === "MemeCreated");
    return parsed.args;
  }

  it("creates and registers a fully configured token/pool pair in one transaction", async function () {
    const [creator] = await ethers.getSigners();
    const { factory, registry } = await deployFactory();
    const created = await create(factory, creator);
    const token = await ethers.getContractAt("FairDot", created.token);
    const pool = await ethers.getContractAt("FairDotPool", created.pool);
    const entry = await registry.getEntry(created.token);

    expect(entry.pool).to.equal(created.pool);
    expect(entry.creator).to.equal(await creator.getAddress());
    expect(await token.name()).to.equal("Fair Meme");
    expect(await token.symbol()).to.equal("FMEME");
    expect(await registry.tokenCount()).to.equal(1n);
    expect(await registry.tokenAt(0)).to.equal(created.token);
    expect(await token.owner()).to.equal(await creator.getAddress());
    expect(await token.liquidityPool()).to.equal(created.pool);
    expect(await token.tradingActive()).to.equal(true);
    expect(await token.mintDisabled()).to.equal(true);
    expect(await token.initialQuoteSeed()).to.equal(10n * S);
    expect(await token.minVolumeBps()).to.equal(500n);
    expect(await token.minVolumeAbsolute()).to.equal(2n * S);
    expect(await pool.owner()).to.equal(await factory.getAddress());
    expect(await pool.tokenReserve()).to.equal(500_000n * S);
    expect(await pool.quoteReserve()).to.equal(10n * S);
    expect(await token.balanceOf(await creator.getAddress())).to.equal(500_000n * S);
    expect((await token.positions(await creator.getAddress())).trackedTokens).to.equal(0n);
  });

  it("lets independent platform clients discover and trade through the same canonical pool", async function () {
    const [creator, platformAUser, platformBUser] = await ethers.getSigners();
    const { factory, registry } = await deployFactory();
    const created = await create(factory, creator);
    const fromRegistryA = await registry.getEntry(created.token);
    const fromRegistryB = await registry.getEntry(created.token);
    expect(await registry.tokenAt(0)).to.equal(created.token);
    expect(fromRegistryA.pool).to.equal(fromRegistryB.pool);

    const poolA = await ethers.getContractAt("FairDotPool", fromRegistryA.pool, platformAUser);
    const poolB = await ethers.getContractAt("FairDotPool", fromRegistryB.pool, platformBUser);
    await poolA.buy(0, { value: S });
    await poolB.buy(0, { value: 2n * S });

    const token = await ethers.getContractAt("FairDot", created.token);
    expect(await token.getLotCount(await platformAUser.getAddress())).to.equal(1n);
    expect(await token.getLotCount(await platformBUser.getAddress())).to.equal(1n);
    expect(await token.balanceOf(await platformAUser.getAddress())).to.be.greaterThan(0n);
    expect(await token.balanceOf(await platformBUser.getAddress())).to.be.greaterThan(0n);
    expect(await token.getQuoteVolume24h()).to.equal(3n * S);
  });

  it("supports multiple token/pool pairs under one shared Registry", async function () {
    const [creatorA, creatorB] = await ethers.getSigners();
    const { factory, registry } = await deployFactory();
    const first = await create(factory, creatorA, "Meme One", "MEME1");
    const second = await create(factory, creatorB, "Meme Two", "MEME2");

    expect(await registry.tokenCount()).to.equal(2n);
    expect(await registry.tokenAt(0)).to.equal(first.token);
    expect(await registry.tokenAt(1)).to.equal(second.token);
    expect((await registry.getEntry(first.token)).pool).to.equal(first.pool);
    expect((await registry.getEntry(second.token)).pool).to.equal(second.pool);
    expect(first.token).not.to.equal(second.token);
    expect(first.pool).not.to.equal(second.pool);
  });

  it("reverts invalid launches atomically without leaving Registry entries", async function () {
    const [creator] = await ethers.getSigners();
    const { factory, registry } = await deployFactory();
    await expect(factory.connect(creator).createMeme(
      "Bad", "BAD", 1000, 500, 10_001, S, { value: S }
    )).to.be.revertedWith("Bps too high");
    expect(await registry.tokenCount()).to.equal(0n);
  });
});
