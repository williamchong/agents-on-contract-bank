import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  solidity: {
    version: "0.8.27",
    settings: {
      // The lowest hardfork the libraries compile for: OpenZeppelin uses mcopy, and ERC20uRWA transient storage.
      evmVersion: "cancun",
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    baseSepolia: {
      type: "http",
      chainType: "op",
      url: configVariable("BASE_SEPOLIA_RPC_URL"),
    },
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
