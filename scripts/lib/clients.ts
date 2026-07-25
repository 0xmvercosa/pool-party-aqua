import { createPublicClient, defineChain, http } from "viem";
import { arbitrum } from "viem/chains";
import { arbitrumRpcUrl, forkRpcUrl } from "./env.ts";

export function mainnetClient() {
  return createPublicClient({ chain: arbitrum, transport: http(arbitrumRpcUrl()) });
}

/** Anvil fork of Arbitrum. Same chain id so SDK constants resolve identically. */
export const anvilArbitrumFork = defineChain({
  ...arbitrum,
  id: 42161,
  name: "Anvil (Arbitrum fork)",
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

export function forkClient() {
  return createPublicClient({ chain: anvilArbitrumFork, transport: http(forkRpcUrl()) });
}
