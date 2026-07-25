/**
 * Appends every executed fill to docs/FILLS.md (BOT-R5).
 *
 * The honesty framing is baked into the file rather than left to the demo narration: in-window
 * fills come from our own taker wallet and are labelled self-directed settlement proofs
 * everywhere they appear (BOT-R2 v2). A below-spot bid band cannot win arbitrage by
 * construction, so anyone reading this log should know exactly what it does and does not show.
 */
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { DECIMALS } from "./addresses.ts";
import { formatUnits } from "./format.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const DOCS = resolve(HERE, "../../docs");

/**
 * Fork rehearsals write to their own file. `docs/FILLS.md` is a submission artifact and must
 * contain mainnet settlements only: a reviewer scanning it should never have to work out
 * which rows were real, and one mislabelled row would undermine the whole document.
 */
export function fillsPathFor(network: "mainnet" | "fork"): string {
  return resolve(DOCS, network === "mainnet" ? "FILLS.md" : "FILLS_FORK.md");
}

const header = (network: "mainnet" | "fork") => `# FILLS${network === "fork" ? " (FORK REHEARSAL, not real)" : ""}: settlement proofs

Every fill executed against an Active Reserve strategy, appended by \`pnpm taker\` as it runs.
${
  network === "fork"
    ? "\n**Nothing in this file happened on mainnet.** These rows come from `pnpm rehearse:taker`\nagainst a local Anvil fork and exist to show the path works before real money moves. The\nreal settlements live in `FILLS.md`.\n"
    : ""
}

## What these fills are, and what they are not

**These are self-directed settlement proofs.** The fills below were executed by our own taker
wallet against our own strategy. They are not arbitrage profit and they are not organic
demand, and a below-spot bid band cannot win arbitrage by construction: it only becomes the
best bid when the market actually falls into it.

What they DO prove is that the machine settles: a real SwapVM program, shipped to the official
1inch Aqua registry, quoted through the official AquaSwapVMRouter, filled on ${
  network === "fork" ? "a local fork of Arbitrum" : "Arbitrum mainnet"
}, with the maker's capital withdrawn from Aave inside the settlement transaction when the fill
exceeds the hot buffer. That mechanism is the product.

In production the premium is paid by arbitrageurs when price enters the band, and by 1inch
routed flow once aggregation integrates Aqua. During this window the external, real yield is
the Aave carry, which accrues every block whether anyone fills or not.

| # | When (UTC) | Band (strategyHash) | Size in | Size out | Implied px | JIT | Tx |
|---|---|---|---|---|---|---|---|
`;

export type FillRecord = {
  when: Date;
  mandate: string;
  strategyHash: string;
  amountIn: bigint;
  amountOut: bigint;
  jitUnparked: boolean;
  txHash: string;
  network: "mainnet" | "fork";
};

function ensureHeader(path: string, network: "mainnet" | "fork"): void {
  if (!existsSync(path)) {
    writeFileSync(path, header(network));
  }
}

function countRows(path: string): number {
  if (!existsSync(path)) return 0;
  const body = readFileSync(path, "utf8");
  // Data rows start with "| " followed by a digit; the header and separator do not.
  return body.split("\n").filter((line) => /^\|\s*\d+\s*\|/.test(line)).length;
}

export function appendFill(record: FillRecord): number {
  const path = fillsPathFor(record.network);
  ensureHeader(path, record.network);
  const index = countRows(path) + 1;

  const inHuman = formatUnits(record.amountIn, DECIMALS.WETH);
  const outHuman = formatUnits(record.amountOut, DECIMALS.USDC);
  const implied =
    record.amountIn > 0n
      ? (Number(record.amountOut) / 10 ** DECIMALS.USDC / (Number(record.amountIn) / 1e18)).toFixed(2)
      : "n/a";

  const explorer =
    record.network === "mainnet"
      ? `[${record.txHash.slice(0, 10)}...](https://arbiscan.io/tx/${record.txHash})`
      : `${record.txHash.slice(0, 10)}... (fork)`;

  const row =
    `| ${index} | ${record.when.toISOString().replace("T", " ").slice(0, 19)} ` +
    `| ${record.mandate} \`${record.strategyHash.slice(0, 10)}...\` | ${inHuman} WETH | ${outHuman} USDC | $${implied} ` +
    `| ${record.jitUnparked ? "yes" : "no"} | ${explorer} |\n`;

  appendFileSync(path, row);
  return index;
}

/**
 * BOT-R3 support: sum of the WETH "Size in" column across today's mainnet rows. The file IS
 * the ledger (append-only, committed), so the cap survives process restarts.
 */
export function sumMainnetFillsToday(now: Date = new Date()): bigint {
  const path = fillsPathFor("mainnet");
  if (!existsSync(path)) return 0n;
  const today = now.toISOString().slice(0, 10);
  let total = 0n;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!/^\|\s*\d+\s*\|/.test(line)) continue;
    const cells = line.split("|").map((c) => c.trim());
    // cells[0] is empty (leading pipe): [ , #, when, band, size in, size out, ...]
    if (!cells[2]?.startsWith(today)) continue;
    const match = cells[4]?.match(/([0-9]+(?:\.[0-9]+)?) WETH/);
    if (!match?.[1]) continue;
    const [whole, frac = ""] = match[1].split(".");
    total += BigInt(whole ?? "0") * 10n ** 18n + BigInt((frac + "0".repeat(18)).slice(0, 18));
  }
  return total;
}

/** Appended once per strategy so the log says which program each fill settled against. */
export function appendStrategyNote(
  mandate: string,
  strategyHash: string,
  network: "mainnet" | "fork",
): void {
  const path = fillsPathFor(network);
  ensureHeader(path, network);
  const body = readFileSync(path, "utf8");
  if (body.includes(strategyHash)) return;
  appendFileSync(path, `\n<!-- strategy: ${mandate} ${strategyHash} on ${network} -->\n`);
}
