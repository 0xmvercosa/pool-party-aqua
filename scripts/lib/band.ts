/**
 * Band math for concentrateGrowLiquidity2D.
 *
 * The instruction takes sqrt prices in 1e18 fixed point where P = tokenGt / tokenLt in RAW
 * token units (tokenGt/tokenLt ordered by address, not by role). Getting the decimals wrong
 * here silently produces a band nowhere near the market, so the conversion is derived once,
 * here, and pinned by scripts/lib/band.test.ts (exact-arithmetic identities).
 *
 * For our pair WETH (0x82aF..., 18dp) < USDC (0xaf88..., 6dp):
 *   tokenLt = WETH, tokenGt = USDC, P = USDC_raw per WETH_raw
 *   P_x18 = priceUsd * 10^6, i.e. exactly the USDC-decimal representation of the ETH price.
 */
import { instructions } from "@1inch/swap-vm-sdk";
import { DECIMALS, TOKENS } from "./addresses.ts";

const { ConcentrateGrowLiquidity2DArgs } = instructions.concentrate;

export const BPS = 10_000n;
const CHAINLINK_DECIMALS = 8n;

/** Address ordering decides which token is the numerator of P. */
export function orderPair(
  tokenA: `0x${string}`,
  tokenB: `0x${string}`,
): { tokenLt: `0x${string}`; tokenGt: `0x${string}` } {
  return BigInt(tokenA) < BigInt(tokenB)
    ? { tokenLt: tokenA, tokenGt: tokenB }
    : { tokenLt: tokenB, tokenGt: tokenA };
}

/**
 * Convert a Chainlink ETH/USD answer (8dp) to the 1e18 fixed-point raw price the
 * concentrate instruction expects for the WETH/USDC pair.
 *
 * P_x18 = answer * 10^decimalsGt * 10^18 / (10^8 * 10^decimalsLt)
 */
export function ethUsdToRawPriceX18(answerE8: bigint): bigint {
  const { tokenGt } = orderPair(TOKENS.WETH, TOKENS.USDC);
  if (tokenGt.toLowerCase() !== TOKENS.USDC.toLowerCase()) {
    throw new Error("Pair ordering changed: USDC is no longer tokenGt, revisit the conversion");
  }
  const numerator = answerE8 * 10n ** BigInt(DECIMALS.USDC) * 10n ** 18n;
  const denominator = 10n ** CHAINLINK_DECIMALS * 10n ** BigInt(DECIMALS.WETH);
  return numerator / denominator;
}

/** Inverse of the above, for printing a band back as human USD. */
export function rawPriceX18ToEthUsd(rawPriceX18: bigint): number {
  return Number(rawPriceX18) / 10 ** DECIMALS.USDC;
}

export type Band = {
  /** Chainlink spot at build time, 8dp, recorded so the ship is auditable after the fact. */
  spotE8: bigint;
  lowE8: bigint;
  highE8: bigint;
  rawPriceMinX18: bigint;
  rawPriceMaxX18: bigint;
};

/**
 * Build a band from percentage offsets below spot. Offsets are negative bps
 * (production: -1500 / -500; demo: -30 / -10).
 */
export function bandFromSpot(spotE8: bigint, lowOffsetBps: bigint, highOffsetBps: bigint): Band {
  if (lowOffsetBps >= 0n || highOffsetBps >= 0n) {
    throw new Error("Band offsets must be negative: a buy band sits entirely below spot");
  }
  if (lowOffsetBps >= highOffsetBps) {
    throw new Error(`Band low offset ${lowOffsetBps} must be further below spot than high ${highOffsetBps}`);
  }
  const lowE8 = (spotE8 * (BPS + lowOffsetBps)) / BPS;
  const highE8 = (spotE8 * (BPS + highOffsetBps)) / BPS;
  return {
    spotE8,
    lowE8,
    highE8,
    rawPriceMinX18: ethUsdToRawPriceX18(lowE8),
    rawPriceMaxX18: ethUsdToRawPriceX18(highE8),
  };
}

/** The SDK owns the sqrt conversion; we never compute sqrt prices by hand. */
export function concentrateArgsFor(band: Band) {
  return ConcentrateGrowLiquidity2DArgs.fromRawPrices(band.rawPriceMinX18, band.rawPriceMaxX18);
}

export function describeBand(band: Band): string {
  const usd = (e8: bigint) => (Number(e8) / 1e8).toFixed(2);
  return `spot $${usd(band.spotE8)} band $${usd(band.lowE8)} .. $${usd(band.highE8)}`;
}
