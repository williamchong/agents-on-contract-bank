// Runs contracts/spike/SpikeChainProbe.sol on the selected network by eth_call with a state override,
// so a live chain is checked with no key, gas or deployment. Run with --network baseSepolia for
// Base Sepolia, or with no network for the local chain the tests use, to compare the two.
import { artifacts, network } from "hardhat";

const PROBE = "0x00000000000000000000000000000000000c4a1e";
// Named so that Hardhat does not ask the node for its accounts, which public endpoints refuse.
const SENDER = "0x0000000000000000000000000000000000000000";

const { provider, networkName } = await network.getOrCreate();
const { deployedBytecode } = await artifacts.readArtifact("SpikeChainProbe");

const [chainId, block] = (await Promise.all([
  provider.request({ method: "eth_chainId" }),
  provider.request({ method: "eth_blockNumber" }),
])) as string[];
// Called at the block just read, so the block printed is the one measured.
const result = (await provider.request({
  method: "eth_call",
  params: [{ from: SENDER, to: PROBE, data: "0x" }, block, { [PROBE]: { code: deployedBytecode } }],
})) as string;
if (result.length !== 2 + 64 * 5) throw new Error(`Unexpected probe result ${result}: was the state override applied?`);

const [precompile, precompileGas, cardGas, passkeyGas, rsaGas] = result
  .slice(2)
  .match(/.{64}/g)!
  .map((word) => BigInt(`0x${word}`));

console.log(`Network ${networkName}, chain ${BigInt(chainId)}, block ${BigInt(block)}`);
console.log(`P-256 precompile at 0x100: ${precompile === 1n ? "present" : "absent"}, gas ${precompileGas}`);
console.log(`Card (P-256) check gas: ${cardGas}`);
console.log(`Passkey (WebAuthn) check gas: ${passkeyGas}`);
console.log(`Partner RSA-2048 check gas: ${rsaGas}`);

if (precompile !== 1n) throw new Error("The P-256 precompile is missing, so every passkey and card check falls back to Solidity.");
