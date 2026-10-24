// Hardhat config for PortaldotV3 Testnet deployment.
// Matches the proven reference setup: size-optimized (storage deposit per byte),
// EVM shanghai, no metadata, sources in ./src (Foundry-style layout).
require("@nomicfoundation/hardhat-ethers");

const privateKey = process.env.PRIVATE_KEY;

module.exports = {
  solidity: {
    version: "0.8.24",
    // PortaldotV3 charges a storage deposit per byte of deployed code, so optimise for size.
    settings: {
      optimizer: { enabled: true, runs: 1 },
      viaIR: true,
      evmVersion: "shanghai",
      metadata: { bytecodeHash: "none", appendCBOR: false },
    },
  },
  networks: {
    portaldotv3Testnet: {
      url: process.env.PORTALDOTV3_TESTNET_RPC_URL || "https://test-evm-rpc-v3.portaldot.dev",
      chainId: 420420777,
      accounts: privateKey ? [privateKey] : [],
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 420420777,
      accounts: privateKey ? [privateKey] : [],
    },
  },
  paths: {
    sources: "./src",
    artifacts: "./hh-artifacts",
    cache: "./hh-cache",
  },
};
