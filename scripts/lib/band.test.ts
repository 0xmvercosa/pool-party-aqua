import { describe, expect, it } from "vitest";

import { TOKENS } from "./addresses.ts";
import { bandFromSpot, ethUsdToRawPriceX18, orderPair, rawPriceX18ToEthUsd } from "./band.ts";

// The conversion header derives: for WETH(18dp) < USDC(6dp), P_x18 is exactly the
// USDC-decimal representation of the USD price. Pin that identity with exact arithmetic.
describe("ethUsdToRawPriceX18", () => {
  it("maps a Chainlink 8dp answer to the USDC-decimal raw price", () => {
    expect(ethUsdToRawPriceX18(3_000_00000000n)).toBe(3_000n * 10n ** 6n);
    expect(ethUsdToRawPriceX18(1_00000000n)).toBe(1_000_000n);
  });

  it("round-trips through the human-readable inverse", () => {
    expect(rawPriceX18ToEthUsd(ethUsdToRawPriceX18(2_547_12000000n))).toBeCloseTo(2547.12, 6);
  });
});

describe("orderPair", () => {
  it("orders WETH below USDC by address, the assumption the conversion rests on", () => {
    const { tokenLt, tokenGt } = orderPair(TOKENS.WETH, TOKENS.USDC);
    expect(tokenLt.toLowerCase()).toBe(TOKENS.WETH.toLowerCase());
    expect(tokenGt.toLowerCase()).toBe(TOKENS.USDC.toLowerCase());
  });
});

describe("bandFromSpot", () => {
  it("builds the demo band strictly below spot with low under high", () => {
    const spot = 3_000_00000000n;
    const band = bandFromSpot(spot, -30n, -10n);
    expect(band.lowE8).toBe((spot * 9_970n) / 10_000n);
    expect(band.highE8).toBe((spot * 9_990n) / 10_000n);
    expect(band.lowE8 < band.highE8 && band.highE8 < spot).toBe(true);
    expect(band.rawPriceMinX18 < band.rawPriceMaxX18).toBe(true);
  });

  it("rejects non-negative offsets and inverted bounds", () => {
    expect(() => bandFromSpot(3_000_00000000n, 0n, -10n)).toThrow();
    expect(() => bandFromSpot(3_000_00000000n, -10n, -30n)).toThrow();
  });
});
