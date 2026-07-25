/**
 * POO-1066: the taker.
 *
 * Reconstructs a live strategy from its on-chain `Shipped` event (never from our database or
 * our compiler), dry-runs `quote()`, and optionally executes a real fill. Every executed fill
 * is appended to docs/FILLS.md and labelled a self-directed settlement proof (BOT-R2 v2).
 *
 * The bot wallet is separate from the manager and keeper keys and holds only its own working
 * capital (BOT-R4). It never touches vault funds.
 *
 * Usage (DRY-RUN IS THE DEFAULT; nothing is sent without --execute):
 *   pnpm taker --strategy 0x... --size 0.01                      (quote only)
 *   pnpm taker --strategy 0x... --size 0.01 --network mainnet --execute
 *   pnpm taker --strategy 0x... --size 0.5  --network fork --execute   (forces the JIT path)
 *   Optional: --slippage-bps 50 (bind the quote on-chain via TakerTraits threshold)
 */
import { relative } from "node:path";
import { Address, Order, SwapVMContract, TakerTraits } from "@1inch/swap-vm-sdk";
import {
  http,
  type PublicClient,
  createPublicClient,
  createWalletClient,
  decodeFunctionResult,
  erc20Abi,
  parseEther,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { AQUA_SWAP_VM_ROUTER, DECIMALS, TOKENS } from "./lib/addresses.ts";
import { anvilArbitrumFork } from "./lib/clients.ts";
import { arbitrumRpcUrl, forkRpcUrl } from "./lib/env.ts";
import { TOPICS, parsePulled, parsePushed, parseSwapped, topicOf } from "./lib/events.ts";
import { appendFill, appendStrategyNote, fillsPathFor, sumMainnetFillsToday } from "./lib/fills.ts";
import { formatUnits, heading, info } from "./lib/format.ts";
import { reconstructFromChain } from "./lib/reconstruct.ts";

/** BOT-R3: hard caps. A bug in size handling must not become a large mainnet trade. */
const MAX_FILL_WETH = parseEther("1");
/** BOT-R3: daily cumulative cap across all mainnet fills, summed from docs/FILLS.md. */
const MAX_DAILY_WETH = parseEther("3");
/** Default slippage bound between the dry-run quote and on-chain execution. */
const DEFAULT_SLIPPAGE_BPS = 50n;

type Args = Record<string, string | boolean>;

function parseArgs(argv: string[]): Args {
  const args: Args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token?.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) {
      args[key] = next;
      i += 1;
    } else {
      args[key] = true;
    }
  }
  return args;
}

const QUOTE_RESULT_ABI = [
  {
    type: "function",
    name: "quote",
    inputs: [],
    outputs: [
      { name: "amountIn", type: "uint256" },
      { name: "amountOut", type: "uint256" },
    ],
    stateMutability: "view",
  },
] as const;

async function quote(
  client: PublicClient,
  order: Order,
  amountIn: bigint,
): Promise<{ amountIn: bigint; amountOut: bigint }> {
  const data = SwapVMContract.encodeQuoteCallData({
    order,
    tokenIn: new Address(TOKENS.WETH),
    tokenOut: new Address(TOKENS.USDC),
    amount: amountIn,
    takerTraits: TakerTraits.default(),
  });
  const result = await client.call({
    to: AQUA_SWAP_VM_ROUTER,
    data: data.toString() as `0x${string}`,
  });
  const [ai, ao] = decodeFunctionResult({
    abi: QUOTE_RESULT_ABI,
    functionName: "quote",
    data: result.data as `0x${string}`,
  });
  return { amountIn: ai, amountOut: ao };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const strategyHash = typeof args.strategy === "string" ? (args.strategy as `0x${string}`) : undefined;
  if (!strategyHash) throw new Error("Missing --strategy <strategyHash>");

  const network = args.network === "mainnet" ? "mainnet" : "fork";
  // Dry-run is the DEFAULT: a taker invocation with no flags must never trade (review fix).
  const execute = args.execute === true;
  const dryRun = !execute;
  const slippageBps = typeof args["slippage-bps"] === "string" ? BigInt(args["slippage-bps"]) : DEFAULT_SLIPPAGE_BPS;
  const mandateLabel = typeof args.mandate === "string" ? args.mandate : "unlabelled";
  const size = parseEther(String(args.size ?? "0.01"));

  if (size > MAX_FILL_WETH) {
    throw new Error(`BOT-R3: --size ${formatUnits(size, 18)} WETH exceeds the ${formatUnits(MAX_FILL_WETH, 18)} cap`);
  }
  if (network === "mainnet" && execute) {
    const already = sumMainnetFillsToday();
    if (already + size > MAX_DAILY_WETH) {
      throw new Error(
        `BOT-R3: today's mainnet fills total ${formatUnits(already, 18)} WETH; ` +
          `adding ${formatUnits(size, 18)} would exceed the ${formatUnits(MAX_DAILY_WETH, 18)} daily cap`,
      );
    }
  }

  const chain = network === "mainnet" ? arbitrum : anvilArbitrumFork;
  const rpc = network === "mainnet" ? arbitrumRpcUrl() : forkRpcUrl();
  const client = createPublicClient({ chain, transport: http(rpc) }) as PublicClient;

  console.log(`Active Reserve taker: ${network}, strategy ${strategyHash}`);
  console.log("Fills produced here are SELF-DIRECTED SETTLEMENT PROOFS, not arbitrage profit.");

  heading("1. Reconstruct the order from chain data alone");
  const strategy = await reconstructFromChain(client, strategyHash);
  info(`maker ${strategy.maker}`);
  info(`app   ${strategy.app}`);
  info(`ship  ${strategy.shipTxHash} (block ${strategy.shipBlock})`);
  info("program, decoded straight from the Shipped event:");
  for (const line of strategy.instructions) info(`  ${line}`);
  info("Nothing above came from our database or our compiler: a stranger with an RPC gets the same.");

  heading("2. Dry-run quote");
  const q = await quote(client, strategy.order, size);
  const implied = Number(q.amountOut) / 10 ** DECIMALS.USDC / (Number(q.amountIn) / 1e18);
  info(`in  ${formatUnits(q.amountIn, DECIMALS.WETH)} WETH`);
  info(`out ${formatUnits(q.amountOut, DECIMALS.USDC)} USDC`);
  info(`implied price $${implied.toFixed(2)} per ETH`);
  if (q.amountOut === 0n) {
    throw new Error("Quote returned zero out; the strategy is docked, expired, or out of depth.");
  }

  if (dryRun) {
    console.log("\n[dry-run] no transaction sent. Pass --execute to fill for real.");
    return;
  }

  heading("3. Execute the fill");
  const key = process.env.TAKER_BOT_PRIVATE_KEY;
  if (!key) throw new Error("TAKER_BOT_PRIVATE_KEY is not set; refusing to guess a signer");
  const account = privateKeyToAccount(key as `0x${string}`);
  const wallet = createWalletClient({ account, chain, transport: http(rpc) });
  info(`taker wallet ${account.address} (its own working capital only, BOT-R4)`);

  const balance = await client.readContract({
    address: TOKENS.WETH,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account.address],
  });
  if (balance < size) {
    throw new Error(
      `Taker holds ${formatUnits(balance, 18)} WETH but the fill needs ${formatUnits(size, 18)}.`,
    );
  }

  const allowance = await client.readContract({
    address: TOKENS.WETH,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account.address, AQUA_SWAP_VM_ROUTER],
  });
  if (allowance < size) {
    info("approving WETH to the router");
    const approveTx = await wallet.writeContract({
      address: TOKENS.WETH,
      abi: erc20Abi,
      functionName: "approve",
      args: [AQUA_SWAP_VM_ROUTER, MAX_FILL_WETH * 100n],
    });
    await client.waitForTransactionReceipt({ hash: approveTx });
    info(`approve ${approveTx}`);
  }

  // Bind the dry-run quote on-chain: threshold = quoted out minus the slippage allowance.
  // TakerTraits enforces it in the router (trap C already showed TakerTraits reverts), so a
  // quote that moves between step 2 and execution cannot fill below the bound (review fix).
  const minOut = (q.amountOut * (10_000n - slippageBps)) / 10_000n;
  info(`min out bound ${formatUnits(minOut, DECIMALS.USDC)} USDC (quote - ${slippageBps} bps)`);
  const swapData = SwapVMContract.encodeSwapCallData({
    order: strategy.order,
    tokenIn: new Address(TOKENS.WETH),
    tokenOut: new Address(TOKENS.USDC),
    amount: size,
    takerTraits: TakerTraits.default().with({ threshold: minOut }),
  });
  const swapTx = await wallet.sendTransaction({
    to: AQUA_SWAP_VM_ROUTER,
    data: swapData.toString() as `0x${string}`,
  });
  const receipt = await client.waitForTransactionReceipt({ hash: swapTx });
  info(`swap ${swapTx} status=${receipt.status} gas=${receipt.gasUsed}`);

  heading("4. Decode the settlement");
  let amountIn = 0n;
  let amountOut = 0n;
  for (const log of receipt.logs) {
    switch (topicOf(log)) {
      case TOPICS.pulled: {
        const e = parsePulled(log);
        info(`Pulled  ${e.token} ${e.amount}`);
        break;
      }
      case TOPICS.pushed: {
        const e = parsePushed(log);
        info(`Pushed  ${e.token} ${e.amount}`);
        break;
      }
      case TOPICS.swapped: {
        const e = parseSwapped(log);
        amountIn = e.amountIn;
        amountOut = e.amountOut;
        info(`Swapped in=${e.amountIn} out=${e.amountOut}`);
        break;
      }
    }
  }

  /**
   * JIT detection without guessing: the maker hook fires only when the vault is short, and the
   * carry adapter is the only other party that moves the quote token in this transaction. An
   * ERC-20 Transfer of USDC INTO the maker during the same tx therefore means the vault
   * unparked to cover the fill.
   */
  const transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
  const makerTopic = `0x${strategy.maker.slice(2).toLowerCase().padStart(64, "0")}`;
  const jitUnparked = receipt.logs.some(
    (log) =>
      log.address.toLowerCase() === TOKENS.USDC.toLowerCase() &&
      log.topics[0] === transferTopic &&
      log.topics[2]?.toLowerCase() === makerTopic,
  );
  info(
    jitUnparked
      ? "JIT PATH HIT: the maker was topped up from the carry sleeve inside this transaction"
      : "no JIT top-up: the fill fit inside the maker's hot buffer",
  );

  if (receipt.status === "success" && amountIn > 0n) {
    appendStrategyNote(mandateLabel, strategyHash, network);
    const index = appendFill({
      when: new Date(),
      mandate: mandateLabel,
      strategyHash,
      amountIn,
      amountOut,
      jitUnparked,
      txHash: swapTx,
      network,
    });
    info(`recorded as fill #${index} in ${relative(process.cwd(), fillsPathFor(network))}`);
  }

  if (receipt.status !== "success") process.exitCode = 1;
}

main().catch((error) => {
  console.error(`\n${(error as Error).message}`);
  process.exitCode = 1;
});
