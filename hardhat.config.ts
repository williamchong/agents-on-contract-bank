import { defineConfig } from "hardhat/config";

export default defineConfig({
  solidity: {
    version: "0.8.27",
    settings: {
      // The lowest hardfork the libraries compile for: OpenZeppelin uses mcopy, and ERC20uRWA transient storage.
      evmVersion: "cancun",
      optimizer: { enabled: true, runs: 200 },
    },
  },
});
