require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1
      },
      viaIR: true,
      evmVersion: "shanghai",
      metadata: {
        bytecodeHash: "none",
        appendCBOR: false
      }
    }
  },
  networks: {
    hardhat: {},
    portaldotv3Testnet: {
      url: process.env.PORTALDOTV3_TESTNET_RPC_URL || "https://test-evm-rpc-v3.portaldot.dev",
      chainId: 420420777,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : "remote",
    }
  },
  paths: {
    sources: "./src",
    tests: "./test",
    cache: "./hh-cache",
    artifacts: "./hh-artifacts"
  }
};
