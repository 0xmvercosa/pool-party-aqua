import { config } from "dotenv";

config({ quiet: true });

/** Public Arbitrum RPC. Fine for reads; override with ARBITRUM_RPC_URL for anything heavier. */
const DEFAULT_ARBITRUM_RPC = "https://arb1.arbitrum.io/rpc";

export function arbitrumRpcUrl(): string {
  return process.env.ARBITRUM_RPC_URL ?? DEFAULT_ARBITRUM_RPC;
}

/** Local Anvil fork endpoint used by the rehearsal. */
export function forkRpcUrl(): string {
  return process.env.FORK_RPC_URL ?? "http://127.0.0.1:8545";
}

export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var ${name} (set it in .env, never in code)`);
  return value;
}
