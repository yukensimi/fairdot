const { expect } = require("chai");
const { ethers } = require("hardhat");

const S = 10n ** 18n;
const DAY = 24 * 60 * 60;
const SUPPLY = 1_000_000_000n;
const TOKEN_SEED = 700_000_000n;
const QUOTE_SEED = 50n * S;
const MIN_VOLUME_BPS = 1_000n;
const MIN_VOLUME_ABSOLUTE = S;

async function deploy(name, args = []) {
  const factory = await ethers.getContractFactory(name);
  const contract = await factory.deploy(...args);
  const receipt = await contract.deploymentTransaction().wait();
  return { contract, deploymentGas: receipt.gasUsed };
}

async function deployCloneSystem() {
  const [deployer, creator, user1, user2, user3] = await ethers.getSigners();
  const { contract: factory, deploymentGas: factoryDeploymentGas } = await deploy("FairDotCloneFactory");
  const tokenImplementation = await ethers.getContractAt("FairDotClone", await factory.tokenImplementation());
  const poolImplementation = await ethers.getContractAt("FairDotPoolClone", await factory.poolImplementation());
  return {
    deployer, creator, user1, user2, user3,
    tokenImplementation, poolImplementation, factory,
    factoryDeploymentGas,
  };
}

async function launch(factory, creator, name = "Clone Meme", symbol = "CLM") {
  const tx = await factory.connect(creator).createMeme(
    name,
    symbol,
    SUPPLY,
    TOKEN_SEED,
    MIN_VOLUME_BPS,
    MIN_VOLUME_ABSOLUTE,
    { value: QUOTE_SEED }
  );
  const receipt = await tx.wait();
  const event = receipt.logs
    .map(log => { try { return factory.interface.parseLog(log); } catch { return null; } })
    .find(parsed => parsed?.name === "MemeCreated");
  return { receipt, tokenAddress: event.args.token, poolAddress: event.args.pool };
}

async function mineAfter(seconds) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

describe("Experimental cloneable FairDot/Pool prototype (local Hardhat only)", function () {
  it("locks implementations, initializes each clone once, and registers the actual creator and canonical pool", async function () {
    const { creator, user1, tokenImplementation, poolImplementation, factory } = await deployCloneSystem();
    await expect(tokenImplementation.initializeClone("Bad", "BAD", SUPPLY))
      .to.be.revertedWith("Only clone factory");
    await expect(poolImplementation.initializeClone(await tokenImplementation.getAddress(), creator.address))
      .to.be.revertedWith("Only clone factory");

    const first = await launch(factory, creator, "First Clone", "FC1");
    const token = await ethers.getContractAt("FairDotClone", first.tokenAddress);
    const pool = await ethers.getContractAt("FairDotPoolClone", first.poolAddress);
    const registry = await ethers.getContractAt("FairDotRegistry", await factory.registry());
    const entry = await registry.getEntry(first.tokenAddress);

    expect(await token.name()).to.equal("First Clone");
    expect(await token.symbol()).to.equal("FC1");
    expect(await token.owner()).to.equal(creator.address);
    expect(await token.totalSupply()).to.equal(SUPPLY * S);
    expect(await token.tradingActive()).to.equal(true);
    expect(await token.mintDisabled()).to.equal(true);
    expect(await token.liquidityPool()).to.equal(first.poolAddress);
    expect(await pool.token()).to.equal(first.tokenAddress);
    expect(await pool.owner()).to.equal(await factory.getAddress());
    expect(await pool.liquidityInitialized()).to.equal(true);
    expect(await token.initialQuoteSeed()).to.equal(QUOTE_SEED);
    expect(await token.balanceOf(first.poolAddress)).to.equal(TOKEN_SEED * S);
    expect(await token.balanceOf(creator.address)).to.equal((SUPPLY - TOKEN_SEED) * S);
    expect(entry.pool).to.equal(first.poolAddress);
    expect(entry.creator).to.equal(creator.address);

    await expect(token.connect(user1).initializeClone("Hijack", "BAD", 1n))
      .to.be.revertedWith("Only clone factory");
    await expect(pool.connect(user1).initializeClone(first.tokenAddress, user1.address))
      .to.be.revertedWith("Only clone factory");

    const factoryAddress = await factory.getAddress();
    await ethers.provider.send("hardhat_setBalance", [factoryAddress, "0x1000000000000000000"]);
    await ethers.provider.send("hardhat_impersonateAccount", [factoryAddress]);
    const factorySigner = await ethers.getSigner(factoryAddress);
    await expect(token.connect(factorySigner).initializeClone("Replay", "RPL", 1n))
      .to.be.revertedWith("Already initialized");
    await expect(pool.connect(factorySigner).initializeClone(first.tokenAddress, factoryAddress))
      .to.be.revertedWith("Already initialized");
    await ethers.provider.send("hardhat_stopImpersonatingAccount", [factoryAddress]);

    const second = await launch(factory, user1, "Second Clone", "FC2");
    const token2 = await ethers.getContractAt("FairDotClone", second.tokenAddress);
    expect(second.tokenAddress).not.to.equal(first.tokenAddress);
    expect(await token2.name()).to.equal("Second Clone");
    expect(await token2.owner()).to.equal(user1.address);
    expect(await token.name()).to.equal("First Clone");
    expect(await token.owner()).to.equal(creator.address);
    expect(await registry.tokenCount()).to.equal(2n);
  });

  it("runs the real FairDot buy, 5x protection, and ten-day active release path through clones", async function () {
    const { creator, user1, user2, user3, factory } = await deployCloneSystem();
    const launched = await launch(factory, creator);
    const token = await ethers.getContractAt("FairDotClone", launched.tokenAddress);
    const pool = await ethers.getContractAt("FairDotPoolClone", launched.poolAddress);

    await pool.connect(user1).buy(0, { value: S });
    const buyer = user1.address;
    const firstLot = await token.lots(buyer, 0);
    await pool.connect(user2).buy(0, { value: 500n * S });
    expect(await token.getEffectivePrice()).to.be.greaterThan(firstLot.quoteBasis * S * 5n / firstLot.quantity);

    await pool.connect(user1).checkpointLock();
    const lockedLot = await token.lots(buyer, 0);
    expect(lockedLot.checkpointed).to.equal(true);
    expect(lockedLot.checkpointProfit).to.be.greaterThan(0n);
    expect((await token.positions(buyer)).lockedProfitTokens).to.be.greaterThan(0n);

    const stablePrice = await token.getEffectivePrice();
    const poolAddress = await pool.getAddress();
    await ethers.provider.send("hardhat_setBalance", [poolAddress, "0x1000000000000000000"]);
    await ethers.provider.send("hardhat_impersonateAccount", [poolAddress]);
    const poolSigner = await ethers.getSigner(poolAddress);
    for (let day = 0; day < 10; day++) {
      await mineAfter(DAY + 5);
      await token.connect(poolSigner).recordPrice(stablePrice, S);
    }
    // The checkpoint block itself advances the active clock by a small amount, so add a few
    // seconds beyond ten full active days to test the completed-release boundary unambiguously.
    await mineAfter(5);
    await token.connect(poolSigner).recordPrice(stablePrice, S);

    const [withdrawable, lockedRemaining] = await token.getWithdrawable(buyer);
    expect(lockedRemaining).to.equal(0n);
    expect(withdrawable).to.equal(await token.balanceOf(buyer));
  });

  it("documents unresolved post-checkpoint appreciation behavior after ten active days", async function () {
    const { creator, user1, user2, user3, factory } = await deployCloneSystem();
    const launched = await launch(factory, creator);
    const token = await ethers.getContractAt("FairDotClone", launched.tokenAddress);
    const pool = await ethers.getContractAt("FairDotPoolClone", launched.poolAddress);
    await pool.connect(user1).buy(0, { value: S });
    await pool.connect(user2).buy(0, { value: 500n * S });
    await pool.connect(user1).checkpointLock();

    for (let day = 0; day < 10; day++) {
      await mineAfter(DAY + 5);
      await pool.connect(user3).buy(0, { value: S / 1_000n });
    }
    await mineAfter(5);
    await pool.connect(user3).buy(0, { value: S / 1_000n });

    const [withdrawable, lockedRemaining, currentRatio] = await token.getWithdrawable(user1.address);
    expect(currentRatio).to.be.greaterThan(5n * 10_000n);
    expect(lockedRemaining).to.be.greaterThan(0n);
    expect(withdrawable + lockedRemaining).to.equal(await token.balanceOf(user1.address));
    // This records current behavior for product review; it is not approval that this is the intended policy.
  });

  it("compares actual createMeme gas with the original deployment Factory", async function () {
    const { creator, factoryDeploymentGas, factory: cloneFactory } =
      await deployCloneSystem();
    const { contract: directFactory, deploymentGas: directFactoryDeploymentGas } = await deploy("FairDotFactory");
    const args = ["Gas Compare", "GAS", SUPPLY, TOKEN_SEED, MIN_VOLUME_BPS, MIN_VOLUME_ABSOLUTE];
    const options = { value: QUOTE_SEED };

    const directLaunchGas = await directFactory.connect(creator).createMeme.estimateGas(...args, options);
    const cloneLaunchGas = await cloneFactory.connect(creator).createMeme.estimateGas(...args, options);
    console.log(`Original FairDotFactory deployment gas (one-time): ${directFactoryDeploymentGas}`);
    console.log(`Clone system deployment gas (implementations + factory + Registry, one-time): ${factoryDeploymentGas}`);
    console.log(`Original createMeme estimate: ${directLaunchGas}`);
    console.log(`Clone createMeme estimate: ${cloneLaunchGas}`);
    console.log(`Clone per-launch reduction: ${((Number(directLaunchGas - cloneLaunchGas) / Number(directLaunchGas)) * 100).toFixed(2)}%`);

    expect(cloneLaunchGas).to.be.lessThan(directLaunchGas);
    const direct = await launch(directFactory, creator, "Direct Control", "DCT");
    const cloned = await launch(cloneFactory, creator, "Clone Control", "CCT");
    const directToken = await ethers.getContractAt("FairDot", direct.tokenAddress);
    const clonedToken = await ethers.getContractAt("FairDotClone", cloned.tokenAddress);
    expect(await directToken.tradingActive()).to.equal(true);
    expect(await clonedToken.tradingActive()).to.equal(true);
  });
});
