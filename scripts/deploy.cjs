// Deploy script for FairDot on PortaldotV3 Testnet.
// Usage: npm run deploy:portaldotv3
// Matches the proven reference deployment pattern (CommonJS .cjs).
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  if (!deployer) throw new Error("Set PRIVATE_KEY to a funded PortaldotV3 EVM account.");

  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)),
    "tPOTv3"
  );

  // ============================================================
  // 1. Deploy FairDot token
  // ============================================================
  const TOKEN_NAME = "FairDot";
  const TOKEN_SYMBOL = "FAIR";
  const INITIAL_SUPPLY = 1_000_000_000; // 1 billion tokens

  console.log("\n=== Deploying FairDot Token ===");
  const factory = await hre.ethers.getContractFactory("FairDot", deployer);
  const token = await factory.deploy(TOKEN_NAME, TOKEN_SYMBOL, INITIAL_SUPPLY);
  const tx = token.deploymentTransaction();
  const receipt = await tx.wait();

  const tokenAddress = await token.getAddress();
  console.log("FairDot:", tokenAddress);
  console.log("Deploy block:", receipt.blockNumber);
  console.log("Deployer:", deployer.address);

  // ============================================================
  // 2. Deploy MockLiquidityPool (testnet / demo only)
  //    In production, use a real DEX (e.g. Uniswap V2 fork)
  // ============================================================
  console.log("\n=== Deploying MockLiquidityPool (test only) ===");
  const poolFactory = await hre.ethers.getContractFactory("MockLiquidityPool", deployer);
  const mockPool = await poolFactory.deploy(tokenAddress);
  const poolTx = mockPool.deploymentTransaction();
  const poolReceipt = await poolTx.wait();
  const poolAddress = await mockPool.getAddress();
  console.log("MockPool:", poolAddress);
  console.log("Pool deploy block:", poolReceipt.blockNumber);

  // ============================================================
  // 3. Configure the token contract
  // ============================================================
  console.log("\n=== Configuring ===");

  await token.setLiquidityPool(poolAddress);
  console.log("Liquidity pool set to:", poolAddress);

  await token.enableTrading();
  console.log("Trading enabled");

  await token.disableMinting();
  console.log("Minting disabled permanently");

  // ============================================================
  // 4. Summary
  // ============================================================
  console.log("\n" + "=".repeat(60));
  console.log("DEPLOYMENT SUMMARY - PortaldotV3 Testnet (Chain ID: 420420777)");
  console.log("=".repeat(60));
  console.log("FairDot Token: ", tokenAddress);
  console.log("MockPool:      ", poolAddress);
  console.log("Token Name:    ", TOKEN_NAME);
  console.log("Token Symbol:  ", TOKEN_SYMBOL);
  console.log("Initial Supply:", INITIAL_SUPPLY.toLocaleString(), TOKEN_SYMBOL);
  console.log("Deploy block:  ", receipt.blockNumber);
  console.log("Node Console:  https://node-console.portaldot.dev/");
  console.log("=".repeat(60));

  console.log("\n NEXT STEPS:");
  console.log("1. Fund the deployer's mapped SS58 address with tPOTv3 (via Node Console)");
  console.log("2. Add liquidity to the pool");
  console.log("3. Call updateLiquidity() with total liquidity");
  console.log("4. Test with accounts: buy, pump price, sell");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
