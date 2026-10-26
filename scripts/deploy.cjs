// Deploy script for FairDot on PortaldotV3 Testnet.
// Usage: npm run deploy:portaldotv3
const hre = require("hardhat");

const EXPECTED_CHAIN_ID = 420420777n;
const INITIAL_SUPPLY = 1_000_000_000n;
const TOKEN_NAME = "FairDot";
const TOKEN_SYMBOL = "FAIR";

async function estimateDeployment(factory, args, deployerAddress, feePerGas, label) {
  const request = await factory.getDeployTransaction(...args);
  const gasLimit = await hre.ethers.provider.estimateGas({
    ...request,
    from: deployerAddress,
  });
  const estimatedFee = gasLimit * feePerGas;

  console.log(
    `${label}: ${gasLimit.toString()} estimated gas; estimated maximum fee ~${hre.ethers.formatEther(estimatedFee)} tPOTv3`
  );
  return estimatedFee;
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  if (!deployer) throw new Error("Set PRIVATE_KEY to a funded PortaldotV3 EVM account.");

  const provider = hre.ethers.provider;
  const network = await provider.getNetwork();
  if (network.chainId !== EXPECTED_CHAIN_ID) {
    throw new Error(
      `Wrong network: expected chain ID ${EXPECTED_CHAIN_ID}, received ${network.chainId}. Check PORTALDOTV3_TESTNET_RPC_URL.`
    );
  }

  const balance = await provider.getBalance(deployer.address);
  const feeData = await provider.getFeeData();
  const feePerGas = feeData.maxFeePerGas ?? feeData.gasPrice;
  if (feePerGas == null) {
    throw new Error("RPC did not return a usable gas price; cannot estimate deployment cost.");
  }

  console.log("Deployer:", deployer.address);
  console.log("Chain ID:", network.chainId.toString());
  console.log("Balance:", hre.ethers.formatEther(balance), "tPOTv3");

  // Estimate both deployments before sending the first transaction, so an
  // insufficient balance is visible before a partial deployment can occur.
  console.log("\n=== Deployment preflight ===");
  const tokenFactory = await hre.ethers.getContractFactory("FairDot", deployer);
  const tokenFee = await estimateDeployment(
    tokenFactory,
    [TOKEN_NAME, TOKEN_SYMBOL, INITIAL_SUPPLY],
    deployer.address,
    feePerGas,
    "FairDot"
  );

  const poolFactory = await hre.ethers.getContractFactory("MockLiquidityPool", deployer);
  const poolFee = await estimateDeployment(
    poolFactory,
    [hre.ethers.ZeroAddress],
    deployer.address,
    feePerGas,
    "MockLiquidityPool"
  );

  const estimatedTotal = tokenFee + poolFee;
  const estimatedWithBuffer = (estimatedTotal * 120n) / 100n;
  console.log(
    "Combined estimated maximum fee plus 20% buffer:",
    hre.ethers.formatEther(estimatedWithBuffer),
    "tPOTv3"
  );
  if (balance < estimatedWithBuffer) {
    console.warn(
      "WARNING: balance is below the estimated deployment fee plus buffer. The estimate is conservative and the actual charge may differ, but deployment may be rejected. Verify that this H160 account is funded through its mapped SS58 account before continuing."
    );
  }

  if (process.env.PREFLIGHT_ONLY === "1") {
    console.log("PREFLIGHT_ONLY=1: no transaction was sent.");
    return;
  }

  // ============================================================
  // 1. Deploy FairDot token
  // ============================================================
  console.log("\n=== Deploying FairDot Token ===");
  const token = await tokenFactory.deploy(TOKEN_NAME, TOKEN_SYMBOL, INITIAL_SUPPLY);
  const tokenTx = token.deploymentTransaction();
  const tokenReceipt = await tokenTx.wait();

  const tokenAddress = await token.getAddress();
  console.log("FairDot:", tokenAddress);
  console.log("Deploy block:", tokenReceipt.blockNumber);
  console.log("Deployer:", deployer.address);

  // ============================================================
  // 2. Deploy MockLiquidityPool (testnet / demo only)
  //    In production, use a real DEX (e.g. Uniswap V2 fork)
  // ============================================================
  console.log("\n=== Deploying MockLiquidityPool (test only) ===");
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
  console.log("Initial Supply:", Number(INITIAL_SUPPLY).toLocaleString(), TOKEN_SYMBOL);
  console.log("Token deploy block:", tokenReceipt.blockNumber);
  console.log("Pool deploy block: ", poolReceipt.blockNumber);
  console.log("Node Console:  https://node-console.portaldot.dev/");
  console.log("=".repeat(60));

  console.log("\nNEXT STEPS:");
  console.log("1. Fund the deployer's mapped SS58 address with tPOTv3 (via Node Console)");
  console.log("2. Add liquidity to the pool");
  console.log("3. Call updateLiquidity() with total liquidity");
  console.log("4. Test with accounts: buy, pump price, sell");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
