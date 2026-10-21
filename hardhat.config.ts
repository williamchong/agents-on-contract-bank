import hardhatVerify from "@nomicfoundation/hardhat-verify";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatVerify],
  solidity: {
    version: "0.8.27",
    settings: {
      // The lowest hardfork the libraries compile for: OpenZeppelin uses mcopy, and ERC20uRWA transient storage.
      evmVersion: "cancun",
      optimizer: { enabled: true, runs: 200 },
    },
    // Deployed as they are, so the deploy script needs their artifacts too.
    npmFilesToBuild: [
      "@openzeppelin/contracts/access/manager/AccessManager.sol",
      "@openzeppelin/contracts/governance/TimelockController.sol",
      "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913P256Verifier.sol",
    ],
  },
  networks: {
    baseSepolia: {
      type: "http",
      chainType: "op",
      url: configVariable("BASE_SEPOLIA_RPC_URL"),
    },
  },
  // Contract sources are verified on Etherscan, which Basescan shows, and on Sourcify: `pnpm verify:base-sepolia`.
  verify: {
    etherscan: { apiKey: configVariable("ETHERSCAN_API_KEY") },
  },
  test: {
    solidity: {
      profiles: {
        default: {},
        // The compatibility tests on a fork of Base Sepolia, pinned so that runs repeat and the fetched state is cached.
        baseSepolia: {
          forking: {
            url: configVariable("BASE_SEPOLIA_RPC_URL"),
            blockNumber: 47_727_000,
          },
        },
      },
    },
  },
});
