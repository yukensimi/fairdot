const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Experimental EIP-1167 launch spike (local Hardhat only)", function () {
  const NAME = "FairDot Probe";
  const SYMBOL = "FDP";
  const SUPPLY = 1_000_000_000n;
  const TOKEN_SEED = 700_000_000n;
  const QUOTE_SEED = ethers.parseEther("1");

  async function deploy(name) {
    const factory = await ethers.getContractFactory(name);
    const contract = await factory.deploy();
    const receipt = await contract.deploymentTransaction().wait();
    return { contract, deploymentGas: receipt.gasUsed };
  }

  it("benchmarks direct pair creation against clones and verifies per-clone initialization", async function () {
    const [creator, other] = await ethers.getSigners();
    const { contract: directFactory, deploymentGas: directFactoryDeploymentGas } =
      await deploy("DirectLaunchPairFactoryProbe");
    const { contract: cloneFactory, deploymentGas: cloneFactoryDeploymentGas } =
      await deploy("CloneLaunchPairFactoryProbe");

    const args = [NAME, SYMBOL, SUPPLY, TOKEN_SEED];
    const directCreateGas = await directFactory.createMeme.estimateGas(...args, { value: QUOTE_SEED });
    const cloneCreateGas = await cloneFactory.createMeme.estimateGas(...args, { value: QUOTE_SEED });

    console.log(`Direct pair create estimate: ${directCreateGas}`);
    console.log(`Clone pair create estimate: ${cloneCreateGas}`);
    console.log(`Direct factory deployment gas (one-time): ${directFactoryDeploymentGas}`);
    console.log(`Clone factory + implementations deployment gas (one-time): ${cloneFactoryDeploymentGas}`);

    expect(cloneCreateGas).to.be.lessThan(directCreateGas);

    const directReceipt = await (await directFactory.createMeme(...args, { value: QUOTE_SEED })).wait();
    const cloneReceipt = await (await cloneFactory.createMeme(...args, { value: QUOTE_SEED })).wait();
    const directEvent = directReceipt.logs
      .map(log => { try { return directFactory.interface.parseLog(log); } catch { return null; } })
      .find(parsed => parsed?.name === "PairCreated");
    const cloneEvent = cloneReceipt.logs
      .map(log => { try { return cloneFactory.interface.parseLog(log); } catch { return null; } })
      .find(parsed => parsed?.name === "PairCreated");

    const directToken = await ethers.getContractAt("DirectLaunchTokenProbe", directEvent.args.token);
    const directPool = await ethers.getContractAt("DirectLaunchPoolProbe", directEvent.args.pool);
    const cloneToken = await ethers.getContractAt("CloneLaunchTokenProbe", cloneEvent.args.token);
    const clonePool = await ethers.getContractAt("CloneLaunchPoolProbe", cloneEvent.args.pool);

    expect(await cloneToken.creator()).to.equal(creator.address);
    expect(await cloneToken.totalSupply()).to.equal(SUPPLY);
    expect(await cloneToken.name()).to.equal(NAME);
    expect(await clonePool.token()).to.equal(cloneEvent.args.token);
    expect(await clonePool.creator()).to.equal(creator.address);
    expect(await clonePool.tokenReserve()).to.equal(TOKEN_SEED);
    expect(await clonePool.quoteReserve()).to.equal(QUOTE_SEED);
    expect(await directToken.creator()).to.equal(creator.address);
    expect(await directPool.token()).to.equal(directEvent.args.token);

    const tokenImplementation = await cloneFactory.tokenImplementation();
    const poolImplementation = await cloneFactory.poolImplementation();
    const implementationToken = await ethers.getContractAt("CloneLaunchTokenProbe", tokenImplementation);
    const implementationPool = await ethers.getContractAt("CloneLaunchPoolProbe", poolImplementation);
    await expect(implementationToken.initialize(NAME, SYMBOL, other.address, SUPPLY))
      .to.be.revertedWith("Already initialized");
    await expect(implementationPool.initialize(directEvent.args.token, other.address, TOKEN_SEED, QUOTE_SEED))
      .to.be.revertedWith("Already initialized");

    await expect(cloneToken.connect(other).initialize("Attacker", "BAD", other.address, 1n))
      .to.be.revertedWith("Already initialized");

    await cloneFactory.createMeme("Second Probe", "SP2", SUPPLY, TOKEN_SEED, { value: QUOTE_SEED });
    expect(await cloneToken.name()).to.equal(NAME);
    expect(await cloneToken.creator()).to.equal(creator.address);
  });
});
