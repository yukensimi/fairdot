// Deploy the shared FairDotFactory/FairDotRegistry pair on Portaldot V3.
// Usage: PREFLIGHT_ONLY=1 npm run deploy:portaldotv3
//        npm run deploy:portaldotv3
const hre = require("hardhat");

const EXPECTED_CHAIN_ID = 420420777n;
const FACTORY_ENV_NAME = "FAIRDOT_FACTORY_ADDRESS";
const MAX_RUNTIME_CODE_BYTES = 24_576; // EIP-170
const MAX_INITCODE_BYTES = 49_152; // EIP-3860

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  if (!deployer) throw new Error("Set PRIVATE_KEY to a funded Portaldot V3 EVM account.");

  const provider = hre.ethers.provider;
  const network = await provider.getNetwork();
  if (network.chainId !== EXPECTED_CHAIN_ID) {
    throw new Error(`Wrong network: expected ${EXPECTED_CHAIN_ID}, received ${network.chainId}.`);
  }

  const balance = await provider.getBalance(deployer.address);
  const feeData = await provider.getFeeData();
  const feePerGas = feeData.maxFeePerGas ?? feeData.gasPrice;
  if (feePerGas == null) throw new Error("RPC did not return a usable gas price.");

  const factoryArtifact = await hre.ethers.getContractFactory("FairDotFactory", deployer);
  const artifact = await hre.artifacts.readArtifact("FairDotFactory");
  const runtimeBytes = (artifact.deployedBytecode.length - 2) / 2;
  const initcodeBytes = (artifact.bytecode.length - 2) / 2;
  if (runtimeBytes > MAX_RUNTIME_CODE_BYTES) {
    throw new Error(`Factory runtime code is ${runtimeBytes} bytes; the EIP-170 limit is ${MAX_RUNTIME_CODE_BYTES}.`);
  }
  if (initcodeBytes > MAX_INITCODE_BYTES) {
    throw new Error(`Factory initcode is ${initcodeBytes} bytes; the EIP-3860 limit is ${MAX_INITCODE_BYTES}.`);
  }
  const request = await factoryArtifact.getDeployTransaction();
  const gasLimit = await provider.estimateGas({ ...request, from: deployer.address });
  const estimatedFee = gasLimit * feePerGas;
  const bufferedFee = estimatedFee * 120n / 100n;

  console.log("Deployer:", deployer.address);
  console.log("Chain ID:", network.chainId.toString());
  console.log("Balance:", hre.ethers.formatEther(balance), "tPOTv3");
  console.log("\n=== Shared Factory deployment preflight ===");
  console.log(`Factory bytecode: ${runtimeBytes}/${MAX_RUNTIME_CODE_BYTES} runtime bytes; ${initcodeBytes}/${MAX_INITCODE_BYTES} initcode bytes`);
  console.log("Factory + Registry deployment gas:", gasLimit.toString());
  console.log("Estimated maximum fee:", hre.ethers.formatEther(estimatedFee), "tPOTv3");
  console.log("Fee estimate + 20% buffer:", hre.ethers.formatEther(bufferedFee), "tPOTv3");
  if (balance < bufferedFee) {
    console.warn("WARNING: balance is below the estimated fee plus buffer. Deployment may be rejected.");
  }

  if (process.env.PREFLIGHT_ONLY === "1") {
    console.log("PREFLIGHT_ONLY=1: no transaction was sent.");
    return;
  }

  console.log("\nDeploying the shared Factory and its Registry. This sends one on-chain transaction.");
  const factory = await factoryArtifact.deploy();
  const deployment = factory.deploymentTransaction();
  const receipt = await deployment.wait();
  const factoryAddress = await factory.getAddress();
  const registryAddress = await factory.registry();

  if ((await provider.getCode(factoryAddress)) === "0x" || (await provider.getCode(registryAddress)) === "0x") {
    throw new Error("Factory deployment receipt exists but deployed code could not be verified.");
  }

  console.log("Factory:", factoryAddress);
  console.log("Registry:", registryAddress);
  console.log("Transaction:", receipt.hash);
  console.log("Block:", receipt.blockNumber);
  console.log(`\nSave ${FACTORY_ENV_NAME}=${factoryAddress} in the deployment environment.`);
  console.log("Share this same Factory/Registry address with every FairDot-compatible platform.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
