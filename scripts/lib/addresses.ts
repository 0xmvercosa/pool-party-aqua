/**
 * Canonical Arbitrum addresses. Mirrors docs/VERIFIED.md; that file is the source of truth.
 *
 * Gen 1 is DEAD (43 ships, last activity ~2026-04) and MUST NOT be used. Only the gen-2 pair
 * below is referenced by @1inch/swap-vm-sdk@0.3.0 and @1inch/aqua-sdk@0.2.0.
 */

export const CHAIN_ID_ARBITRUM = 42161;

/** Gen 2: the live Aqua registry + AquaSwapVMRouter pair. Each router's AQUA() points at its own registry. */
export const AQUA_REGISTRY = "0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a" as const;
export const AQUA_SWAP_VM_ROUTER = "0x1111113Db0e0ef9D0E3A50d5f094a3a57a26C0DE" as const;

/** Gen 1: recorded so scripts can assert we never touch it. */
export const DEAD_GEN1_REGISTRY = "0x499943e74fb0ce105688beee8ef2abec5d936d31" as const;
export const DEAD_GEN1_ROUTER = "0x8fdd04dbf6111437b44bbca99c28882434e0958f" as const;

export const TOKENS = {
  /** Native Arbitrum USDC (not USDC.e). 6 decimals. */
  USDC: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
  /** Canonical WETH on Arbitrum. 18 decimals. */
  WETH: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
} as const;

export const DECIMALS = {
  USDC: 6,
  WETH: 18,
} as const;

/** Chainlink ETH/USD, 8 decimals. 24h sample: 360 updates, median gap 121s, max 29.5 min. */
export const CHAINLINK_ETH_USD = "0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612" as const;

/** Aave v3 on Arbitrum: the carry leg. */
export const AAVE_V3_POOL = "0x794a61358D6845594F94dc1DB02A252b5b4814aD" as const;
export const AAVE_A_USDC = "0x724dc807b04555b71ed48a6896b6F41593b8C637" as const;

/**
 * Ground-truth reference: gen-2 live ship #0. POO-1058 decodes this to prove our builder
 * round-trips the same structure against a program we did not write.
 */
export const REFERENCE_SHIP_TX =
  "0xa966fc93f4519646528f082bce8640aa69146c9be9f77e4249ff446eba0fc166" as const;

/** Block the gen-2 registry first saw activity; bounds log scans on public RPCs. */
/**
 * Our own deployed maker on the gen-2 registry (POO-1062, 2026-07-25). Verified on Arbiscan.
 * Kept here so the ground-truth verifier can tell OUR ships apart from the pre-existing ones.
 */
export const PARTY_VAULT = "0xec870a6A9E8EE41B349FD0766b8f295D6EDC6610" as const;
export const AAVE_V3_ADAPTER = "0x6d409fF8578D017AddDB2e9Ad0848D8F0A65aBAe" as const;
/** Block of our first ship: everything at or after it on the gen-2 registry is ours. */
export const PARTY_VAULT_FIRST_SHIP_BLOCK = 487665802n;

export const GEN2_FIRST_ACTIVITY_BLOCK = 484000000n;
