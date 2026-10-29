// Create a FairDot token/pool through a previously deployed shared Factory.
// Run with PREFLIGHT_ONLY=1 first; the preflight estimates gas and sends no transaction.
const hre = require("hardhat");

const EXPECTED_CHAIN_ID = 420420777n;
const MAX_RUNTIME_CODE_BYTES = 24_576; // EIP-170
const REQUIRED = [
  "FAIRDOT_FACTORY_ADDRESS",
  "MEME_NAME",
  "MEME_SYMBOL",
  "INITIAL_SUPPLY_TOKENS",
  "SEED_TOKEN_AMOUNT_TOKENS",
  "INITIAL_LIQUIDITY_TPOT",
  "MIN_VOLUME_BPS",
  "MIN_VOLUME_ABSOLUTE_TPOT",
];

function requireEnvironment() {
  const missing = REQUIRED.filter((key) => !process.env[key]);
  if (missing.length) throw new Error(`Set these .env values first: ${missing.join(", ")}`);
}

async function main() {
  requireEnvironment();
  const [creator] = await hre.ethers.getSigners();
  if (!creator) throw new Error("Set PRIVATE_KEY to the funded Portaldot V3 EVM account that will create the token.");

  const provider = hre.ethers.provider;
  const network = await provider.getNetwork();
  if (network.chainId !== EXPECTED_CHAIN_ID) {
    throw new Error(`Wrong network: expected ${EXPECTED_CHAIN_ID}, received ${network.chainId}.`);
  }

  const factoryAddress = hre.ethers.getAddress(process.env.FAIRDOT_FACTORY_ADDRESS);
  const factoryCode = await provider.getCode(factoryAddress);
  if (factoryCode === "0x") {
    throw new Error(`No contract code at FAIRDOT_FACTORY_ADDRESS ${factoryAddress}.`);
  }
  const factoryCodeBytes = (factoryCode.length - 2) / 2;
  if (factoryCodeBytes > MAX_RUNTIME_CODE_BYTES) {
    throw new Error(`Factory runtime code is ${factoryCodeBytes} bytes; the EIP-170 limit is ${MAX_RUNTIME_CODE_BYTES}.`);
  }

  const name = process.env.MEME_NAME.trim();
  const symbol = process.env.MEME_SYMBOL.trim();
  const supply = BigInt(process.env.INITIAL_SUPPLY_TOKENS);
  const seedTokens = BigInt(process.env.SEED_TOKEN_AMOUNT_TOKENS);
  const minBps = BigInt(process.env.MIN_VOLUME_BPS);
  const minAbsolute = hre.ethers.parseEther(process.env.MIN_VOLUME_ABSOLUTE_TPOT);
  const quoteSeed = hre.ethers.parseEther(process.env.INITIAL_LIQUIDITY_TPOT);

  if (!name || name.length > 32) throw new Error("MEME_NAME must contain 1–32 characters.");
  if (!symbol || symbol.length > 12) throw new Error("MEME_SYMBOL must contain 1–12 characters.");
  if (supply <= 0n || seedTokens <= 0n || seedTokens > supply) {
    throw new Error("Supply and seed token amounts must be positive; token seed cannot exceed total supply.");
  }
  if (minBps < 0n || minBps > 10_000n || (minBps === 0n && minAbsolute === 0n)) {
    throw new Error("Use MIN_VOLUME_BPS from 0 to 10000 and a non-zero percentage or absolute threshold.");
  }
  if (quoteSeed <= 0n) throw new Error("INITIAL_LIQUIDITY_TPOT must be greater than zero.");

  const factory = await hre.ethers.getContractAt("FairDotFactory", factoryAddress, creator);
  const registryAddress = await factory.registry();
  const feeData = await provider.getFeeData();
  const feePerGas = feeData.maxFeePerGas ?? feeData.gasPrice;
  if (feePerGas == null) throw new Error("RPC did not return a usable gas price.");

  const args = [name, symbol, supply, seedTokens, minBps, minAbsolute];
  const gasLimit = await factory.createMeme.estimateGas(...args, { value: quoteSeed });
  const estimatedFee = gasLimit * feePerGas;
  const bufferedFee = estimatedFee * 120n / 100n;
  const totalNeeded = quoteSeed + bufferedFee;
  const balance = await provider.getBalance(creator.address);

  console.log("Creator:", creator.address);
  console.log("Chain ID:", network.chainId.toString());
  console.log("Factory:", factoryAddress);
  console.log(`Factory runtime bytecode: ${factoryCodeBytes}/${MAX_RUNTIME_CODE_BYTES} bytes`);
  console.log("Registry:", registryAddress);
  console.log("Token:", `${name} (${symbol})`);
  console.log("Initial supply:", supply.toString(), "whole tokens");
  console.log("Token seed:", seedTokens.toString(), "whole tokens");
  console.log("Native quote seed:", hre.ethers.formatEther(quoteSeed), "tPOTv3");
  console.log("Minimum volume:", `${minBps.toString()} bps or ${hre.ethers.formatEther(minAbsolute)} tPOTv3, whichever is greater`);
  console.log("Estimated gas:", gasLimit.toString());
  console.log("Estimated max fee + 20% buffer:", hre.ethers.formatEther(bufferedFee), "tPOTv3");
  console.log("Estimated seed + fee requirement:", hre.ethers.formatEther(totalNeeded), "tPOTv3");
  console.log("Balance:", hre.ethers.formatEther(balance), "tPOTv3");
  if (balance < totalNeeded) console.warn("WARNING: account balance may not cover the quote seed plus deployment fee buffer.");

  if (process.env.PREFLIGHT_ONLY === "1") {
    console.log("PREFLIGHT_ONLY=1: no transaction was sent.");
    return;
  }

  console.log("\nCreating token and pool via the shared Factory. This sends one on-chain transaction.");
  const tx = await factory.createMeme(...args, { value: quoteSeed });
  const receipt = await tx.wait();
  const parsed = receipt.logs
    .map((log) => { try { return factory.interface.parseLog(log); } catch { return null; } })
    .find((log) => log && log.name === "MemeCreated");
  if (!parsed) throw new Error(`Transaction ${receipt.hash} succeeded but MemeCreated event was not found; do not blindly rerun.`);

  const { token, pool, creator: eventCreator } = parsed.args;
  const registry = await hre.ethers.getContractAt("FairDotRegistry", registryAddress);
  const entry = await registry.getEntry(token);
  const [tokenCode, poolCode] = await Promise.all([provider.getCode(token), provider.getCode(pool)]);
  if (
    tokenCode === "0x" ||
    poolCode === "0x" ||
    entry.pool.toLowerCase() !== pool.toLowerCase() ||
    entry.creator.toLowerCase() !== eventCreator.toLowerCase()
  ) {
    throw new Error(`Transaction ${receipt.hash} succeeded, but Registry verification failed; do not blindly rerun.`);
  }

  console.log("Token:", token);
  console.log("Canonical pool:", pool);
  console.log("Creator:", eventCreator);
  console.log("Transaction:", receipt.hash);
  console.log("Block:", receipt.blockNumber);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
