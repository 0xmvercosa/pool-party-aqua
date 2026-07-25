/**
 * POO-1065 (reduced to a status/report script per the 20h plan): the demo's numbers screen.
 *
 * Reads live state and prints NAV plus a carry-vs-fills attribution. IDX-R2 is the rule that
 * shapes this file: money is always read fresh from chain, never from a cache and never from
 * our own database. If a number here is wrong, it is wrong on Arbitrum too.
 *
 * Attribution (IDX-R4, window scope):
 *   carry = parkedBalance minus net principal parked, reconstructed from the USDC Transfer
 *           legs between vault and adapter. This is the external Aave yield, as a number.
 *   fills = WETH accumulated vs USDC paid, marked at the CURRENT Chainlink spot (not at
 *           fill-time price; per-fill historical marking is a post-window refinement).
 *   The 80 bps premium is embedded in the discount-vs-spot line, not printed separately.
 *
 * Usage:
 *   pnpm status --vault 0x... [--adapter 0x...] [--strategy 0x... --strategy 0x...]
 *   pnpm status --vault 0x... --network fork
 *   (--adapter is optional: when omitted it is read from vault.ADAPTER())
 */
import { http, type PublicClient, createPublicClient, erc20Abi } from "viem";
import { arbitrum } from "viem/chains";
import {
  AAVE_A_USDC,
  AQUA_REGISTRY,
  AQUA_SWAP_VM_ROUTER,
  CHAINLINK_ETH_USD,
  DECIMALS,
  TOKENS,
} from "./lib/addresses.ts";
import { anvilArbitrumFork } from "./lib/clients.ts";
import { arbitrumRpcUrl, forkRpcUrl } from "./lib/env.ts";
import { TOPICS, parsePulled, parsePushed, topicOf } from "./lib/events.ts";
import { formatUnits, heading, info } from "./lib/format.ts";

type Args = Record<string, string | string[] | boolean>;

function parseArgs(argv: string[]): Args {
  const args: Args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token?.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    const value: string | boolean = next && !next.startsWith("--") ? next : true;
    if (typeof value === "string") i += 1;
    const existing = args[key];
    if (existing === undefined) args[key] = value;
    else if (Array.isArray(existing)) existing.push(String(value));
    else args[key] = [String(existing), String(value)];
  }
  return args;
}

function asList(value: string | string[] | boolean | undefined): string[] {
  if (value === undefined || typeof value === "boolean") return [];
  return Array.isArray(value) ? value : [value];
}

const CHAINLINK_ABI = [
  {
    type: "function",
    name: "latestRoundData",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
    stateMutability: "view",
  },
] as const;

const AQUA_VIEW_ABI = [
  {
    type: "function",
    name: "rawBalances",
    inputs: [
      { name: "maker", type: "address" },
      { name: "app", type: "address" },
      { name: "strategyHash", type: "bytes32" },
      { name: "token", type: "address" },
    ],
    outputs: [
      { name: "balance", type: "uint248" },
      { name: "tokensCount", type: "uint8" },
    ],
    stateMutability: "view",
  },
] as const;

const PARKED_BALANCE_ABI = [
  {
    type: "function",
    name: "parkedBalance",
    inputs: [{ name: "token", type: "address" }],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
] as const;

const VAULT_VIEW_ABI = [
  { type: "function", name: "ADAPTER", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" },
  { type: "function", name: "totalAssets", inputs: [], outputs: [{ type: "uint256" }], stateMutability: "view" },
] as const;

const usd = (e8: bigint) => (Number(e8) / 1e8).toFixed(2);

/** USDC value of a WETH amount at a given Chainlink price, all in raw units. */
function wethToUsdcRaw(wethRaw: bigint, priceE8: bigint): bigint {
  // wethRaw / 1e18 * (priceE8 / 1e8) * 1e6
  return (wethRaw * priceE8) / BigInt(10) ** BigInt(18 + 8 - 6);
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const vault = typeof args.vault === "string" ? (args.vault as `0x${string}`) : undefined;
  if (!vault) throw new Error("Missing --vault <address>");
  const adapter = typeof args.adapter === "string" ? (args.adapter as `0x${string}`) : undefined;
  const strategies = asList(args.strategy) as `0x${string}`[];
  const network = args.network === "fork" ? "fork" : "mainnet";

  const chain = network === "mainnet" ? arbitrum : anvilArbitrumFork;
  const rpc = network === "mainnet" ? arbitrumRpcUrl() : forkRpcUrl();
  const client = createPublicClient({ chain, transport: http(rpc) }) as PublicClient;

  console.log("ACTIVE RESERVE: live status");
  console.log(`network ${network}, vault ${vault}`);

  // ---- price -------------------------------------------------------------
  const [, priceE8, , updatedAt] = await client.readContract({
    address: CHAINLINK_ETH_USD,
    abi: CHAINLINK_ABI,
    functionName: "latestRoundData",
  });
  const block = await client.getBlock();
  const age = block.timestamp - updatedAt;
  heading("Price");
  info(`Chainlink ETH/USD $${usd(priceE8)} (updated ${age}s ago)`);
  if (age > BigInt(90 * 60)) {
    info("WARNING: past the 90-minute staleness bound (D9). NAV below is not trustworthy.");
  }

  // ---- balances ----------------------------------------------------------
  heading("Balances, read fresh from chain (IDX-R2)");
  const vaultUsdc = await client.readContract({
    address: TOKENS.USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
  });
  const vaultWeth = await client.readContract({
    address: TOKENS.WETH,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [vault],
  });

  // --adapter is optional: the vault knows its adapter (immutable getter), so NAV must not
  // silently understate when the flag is omitted (review fix, IDX-R3).
  let adapterAddr = adapter;
  if (!adapterAddr) {
    try {
      adapterAddr = await client.readContract({
        address: vault,
        abi: VAULT_VIEW_ABI,
        functionName: "ADAPTER",
      });
      info(`adapter ${adapterAddr} (read from vault.ADAPTER())`);
    } catch {
      info("(no --adapter and vault.ADAPTER() unavailable; parked leg will read 0)");
    }
  }
  let parked = BigInt(0);
  if (adapterAddr) {
    try {
      parked = await client.readContract({
        address: adapterAddr,
        abi: PARKED_BALANCE_ABI,
        functionName: "parkedBalance",
        args: [TOKENS.USDC],
      });
    } catch {
      // Before the real adapter exists, fall back to the aToken balance directly.
      parked = await client.readContract({
        address: AAVE_A_USDC,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [adapterAddr],
      });
      info("(adapter has no parkedBalance(); read the aUSDC balance instead)");
    }
  }

  info(`vault USDC (hot buffer) ${formatUnits(vaultUsdc, DECIMALS.USDC)}`);
  info(`vault WETH (accumulated) ${formatUnits(vaultWeth, DECIMALS.WETH)}`);
  info(`parked in Aave           ${formatUnits(parked, DECIMALS.USDC)} USDC`);

  // ---- strategies --------------------------------------------------------
  heading("Strategies (Aqua rawBalances)");
  let committedUsdc = BigInt(0);
  for (const strategyHash of strategies) {
    const [usdcBalance, tokensCount] = await client.readContract({
      address: AQUA_REGISTRY,
      abi: AQUA_VIEW_ABI,
      functionName: "rawBalances",
      args: [vault, AQUA_SWAP_VM_ROUTER, strategyHash, TOKENS.USDC],
    });
    const [wethBalance] = await client.readContract({
      address: AQUA_REGISTRY,
      abi: AQUA_VIEW_ABI,
      functionName: "rawBalances",
      args: [vault, AQUA_SWAP_VM_ROUTER, strategyHash, TOKENS.WETH],
    });
    committedUsdc += usdcBalance;
    info(
      `${strategyHash.slice(0, 12)}... USDC ${formatUnits(usdcBalance, DECIMALS.USDC)} ` +
        `WETH ${formatUnits(wethBalance, DECIMALS.WETH)} tokensCount ${tokensCount}` +
        (tokensCount === 0 ? "  (DOCKED)" : ""),
    );
  }
  if (strategies.length === 0) info("(none passed; add --strategy 0x... to include them)");

  // ---- NAV ---------------------------------------------------------------
  //
  // VLT-R4: totalAssets = wallet USDC + parked + wallet WETH at Chainlink. The Aqua
  // rawBalances are NOT added: shipping is accounting only, the tokens are still in the
  // vault's wallet (proven in POO-1058 trap B). Adding them would double-count.
  heading("NAV (VLT-R4)");
  const wethAsUsdc = wethToUsdcRaw(vaultWeth, priceE8);
  const nav = vaultUsdc + parked + wethAsUsdc;
  info(`wallet USDC        ${formatUnits(vaultUsdc, DECIMALS.USDC)}`);
  info(`parked (Aave)      ${formatUnits(parked, DECIMALS.USDC)}`);
  info(`WETH at Chainlink  ${formatUnits(wethAsUsdc, DECIMALS.USDC)}  (${formatUnits(vaultWeth, DECIMALS.WETH)} WETH @ $${usd(priceE8)})`);
  info(`NAV                ${formatUnits(nav, DECIMALS.USDC)} USDC`);
  // Cross-check the reconstruction against the vault's own view (IDX-R3): any divergence
  // beyond rounding means this script or the vault is wrong, and both claim VLT-R4.
  try {
    const onchainNav = await client.readContract({
      address: vault,
      abi: VAULT_VIEW_ABI,
      functionName: "totalAssets",
    });
    const diff = onchainNav > nav ? onchainNav - nav : nav - onchainNav;
    info(`vault.totalAssets  ${formatUnits(onchainNav, DECIMALS.USDC)} USDC (on-chain cross-check, diff ${formatUnits(diff, DECIMALS.USDC)})`);
    if (diff > BigInt(1_000_000)) {
      info("WARNING: reconstruction diverges from vault.totalAssets by more than 1 USDC");
    }
  } catch {
    info("(vault.totalAssets() unavailable; cross-check skipped)");
  }
  info(
    `committed to strategies ${formatUnits(committedUsdc, DECIMALS.USDC)} USDC ` +
      `(quoted depth, not a separate asset: ship() moves nothing)`,
  );
  const coverage = committedUsdc === BigInt(0) ? null : Number(vaultUsdc + parked) / Number(committedUsdc);
  if (coverage !== null) {
    info(`coverage ${coverage.toFixed(3)}x (liquid quote vs committed; PRG-R6 wants >= 1.0)`);
  }

  // ---- fills and attribution --------------------------------------------
  heading("Fills and attribution (IDX-R4)");
  const searchBlocks = BigInt(String(args["search-blocks"] ?? "3000000"));
  const head = await client.getBlockNumber();
  const floor = head > searchBlocks ? head - searchBlocks : BigInt(0);

  let fills = 0;
  let wethIn = BigInt(0);
  let usdcOut = BigInt(0);
  const chunk = BigInt(100_000);
  let to = head;
  while (to > floor) {
    const from = to > floor + chunk ? to - chunk : floor;
    const logs = await client.getLogs({ address: AQUA_REGISTRY, fromBlock: from, toBlock: to });
    for (const log of logs) {
      if (topicOf(log) === TOPICS.pushed) {
        const e = parsePushed(log);
        if (e.maker.toString().toLowerCase() !== vault.toLowerCase()) continue;
        // Registering the empty side at ship time emits Pushed with amount 0 (PRG-R2).
        // Counting it would inflate the fill count on the demo's numbers screen.
        if (e.amount === BigInt(0)) continue;
        if (e.token.toString().toLowerCase() === TOKENS.WETH.toLowerCase()) {
          wethIn += e.amount;
          fills += 1;
        }
      } else if (topicOf(log) === TOPICS.pulled) {
        const e = parsePulled(log);
        if (e.maker.toString().toLowerCase() !== vault.toLowerCase()) continue;
        if (e.token.toString().toLowerCase() === TOKENS.USDC.toLowerCase()) usdcOut += e.amount;
      }
    }
    if (from === floor) break;
    to = from - BigInt(1);
  }

  info(`fills settled            ${fills}`);
  info(`WETH bought              ${formatUnits(wethIn, DECIMALS.WETH)}`);
  info(`USDC paid                ${formatUnits(usdcOut, DECIMALS.USDC)}`);
  if (wethIn > BigInt(0)) {
    const avgPaid = Number(usdcOut) / 10 ** DECIMALS.USDC / (Number(wethIn) / 1e18);
    const spotNow = Number(priceE8) / 1e8;
    const discountPct = ((spotNow - avgPaid) / spotNow) * 100;
    const markToMarket = wethToUsdcRaw(wethIn, priceE8) - usdcOut;
    info(`average price paid       $${avgPaid.toFixed(2)} per ETH`);
    info(`discount vs spot now     ${discountPct.toFixed(2)}%`);
    info(
      `fill P&L at current spot ${markToMarket >= BigInt(0) ? "+" : ""}${formatUnits(markToMarket, DECIMALS.USDC)} USDC`,
    );
    info("  (this is the dip-buying leg: ETH accumulated below market)");
  }

  // ---- carry, as a number -------------------------------------------------
  // Net principal parked = USDC transferred vault->adapter minus adapter->vault, from the
  // token's own Transfer logs. parkedBalance is interest-inclusive, so the difference IS the
  // Aave carry earned in the scanned window's history (review fix: compute it, not prose).
  heading("Carry (external yield, computed)");
  if (adapterAddr) {
    let principalIn = BigInt(0);
    let principalOut = BigInt(0);
    let t = head;
    while (t > floor) {
      const from = t > floor + chunk ? t - chunk : floor;
      const inLogs = await client.getLogs({
        address: TOKENS.USDC,
        event: { type: "event", name: "Transfer", inputs: [
          { name: "from", type: "address", indexed: true },
          { name: "to", type: "address", indexed: true },
          { name: "value", type: "uint256", indexed: false },
        ] },
        args: { from: vault, to: adapterAddr },
        fromBlock: from,
        toBlock: t,
      });
      const outLogs = await client.getLogs({
        address: TOKENS.USDC,
        event: { type: "event", name: "Transfer", inputs: [
          { name: "from", type: "address", indexed: true },
          { name: "to", type: "address", indexed: true },
          { name: "value", type: "uint256", indexed: false },
        ] },
        args: { from: adapterAddr, to: vault },
        fromBlock: from,
        toBlock: t,
      });
      for (const l of inLogs) principalIn += l.args.value ?? BigInt(0);
      for (const l of outLogs) principalOut += l.args.value ?? BigInt(0);
      if (from === floor) break;
      t = from - BigInt(1);
    }
    const principalNet = principalIn - principalOut;
    const carry = parked - principalNet;
    info(`principal parked (net)   ${formatUnits(principalNet, DECIMALS.USDC)} USDC`);
    info(`parked balance now       ${formatUnits(parked, DECIMALS.USDC)} USDC`);
    info(`carry earned             ${carry >= BigInt(0) ? "+" : ""}${formatUnits(carry, DECIMALS.USDC)} USDC (Aave interest, accrues every block)`);
    info("  (assumes the park/unpark history is inside the scanned window; widen --search-blocks otherwise)");
  } else {
    info("(no adapter known; carry cannot be computed)");
  }

  info("");
  info("The carry above is the only EXTERNAL yield in the window; the fills are self-directed");
  info("settlement proofs.");
}

main().catch((error) => {
  console.error(`\n${(error as Error).message}`);
  process.exitCode = 1;
});
