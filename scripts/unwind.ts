/**
 * Close-out helper: buy the vault's accumulated WETH back through a live strategy
 * (reverse direction: taker pays USDC, receives WETH), so a FULL redemption in USDC
 * becomes possible. The vault has no swap function by design (window cut); settling
 * through the band IS the designed exit for inventory.
 *
 * DRY-RUN IS THE DEFAULT. Usage:
 *   pnpm tsx scripts/unwind.ts --strategy 0x... --usdc-in 0.55 --network mainnet
 *   pnpm tsx scripts/unwind.ts --strategy 0x... --usdc-in 0.55 --network mainnet --execute
 */
import { Address, Order, SwapVMContract, TakerTraits } from "@1inch/swap-vm-sdk";
import { http, type PublicClient, createPublicClient, createWalletClient, decodeFunctionResult, erc20Abi, parseUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import { AQUA_SWAP_VM_ROUTER, DECIMALS, TOKENS } from "./lib/addresses.ts";
import { anvilArbitrumFork } from "./lib/clients.ts";
import { arbitrumRpcUrl, forkRpcUrl } from "./lib/env.ts";
import { TOPICS, parsePulled, parsePushed, parseSwapped, topicOf } from "./lib/events.ts";
import { formatUnits, heading, info } from "./lib/format.ts";
import { reconstructFromChain } from "./lib/reconstruct.ts";

const MAX_FILL_USDC = parseUnits("2", 6); // close-out clips are sub-dollar; 2 USDC is a hard cap
const DEFAULT_SLIPPAGE_BPS = 50n;

const QUOTE_RESULT_ABI = [
  { type: "function", name: "quote", inputs: [], outputs: [
    { name: "amountIn", type: "uint256" }, { name: "amountOut", type: "uint256" },
  ], stateMutability: "view" },
] as const;

function parseArgs(argv: string[]): Record<string, string | boolean> {
  const args: Record<string, string | boolean> = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token?.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) { args[key] = next; i += 1; } else args[key] = true;
  }
  return args;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const strategyHash = typeof args.strategy === "string" ? (args.strategy as `0x${string}`) : undefined;
  if (!strategyHash) throw new Error("Missing --strategy <strategyHash>");
  const usdcIn = parseUnits(String(args["usdc-in"] ?? "0.1"), 6);
  if (usdcIn > MAX_FILL_USDC) throw new Error(`--usdc-in exceeds the ${formatUnits(MAX_FILL_USDC, 6)} USDC close-out cap`);
  const network = args.network === "mainnet" ? "mainnet" : "fork";
  const execute = args.execute === true;
  const slippageBps = typeof args["slippage-bps"] === "string" ? BigInt(args["slippage-bps"]) : DEFAULT_SLIPPAGE_BPS;

  const chain = network === "mainnet" ? arbitrum : anvilArbitrumFork;
  const rpc = network === "mainnet" ? arbitrumRpcUrl() : forkRpcUrl();
  const client = createPublicClient({ chain, transport: http(rpc) }) as PublicClient;

  console.log(`Active Reserve unwind (reverse fill): ${network}, strategy ${strategyHash}`);
  console.log("The taker BUYS the vault's WETH so the vault can be redeemed fully in USDC.");

  heading("1. Reconstruct the order from chain data");
  const strategy = await reconstructFromChain(client, strategyHash);
  info(`maker ${strategy.maker}`);

  heading("2. Dry-run quote (USDC -> WETH)");
  const data = SwapVMContract.encodeQuoteCallData({
    order: strategy.order,
    tokenIn: new Address(TOKENS.USDC),
    tokenOut: new Address(TOKENS.WETH),
    amount: usdcIn,
    takerTraits: TakerTraits.default(),
  });
  const result = await client.call({ to: AQUA_SWAP_VM_ROUTER, data: data.toString() as `0x${string}` });
  const [ai, ao] = decodeFunctionResult({ abi: QUOTE_RESULT_ABI, functionName: "quote", data: result.data as `0x${string}` });
  info(`in  ${formatUnits(ai, DECIMALS.USDC)} USDC`);
  info(`out ${formatUnits(ao, DECIMALS.WETH)} WETH`);
  if (ao === 0n) throw new Error("Zero WETH out: strategy docked, expired, or no WETH inventory at this size.");
  const implied = Number(ai) / 10 ** DECIMALS.USDC / (Number(ao) / 1e18);
  info(`implied price $${implied.toFixed(2)} per ETH`);

  if (!execute) {
    console.log("\n[dry-run] no transaction sent. Pass --execute to fill for real.");
    return;
  }

  heading("3. Execute the reverse fill");
  const key = process.env.TAKER_BOT_PRIVATE_KEY;
  if (!key) throw new Error("TAKER_BOT_PRIVATE_KEY is not set");
  const account = privateKeyToAccount(key as `0x${string}`);
  const wallet = createWalletClient({ account, chain, transport: http(rpc) });

  const usdcBalance = await client.readContract({ address: TOKENS.USDC, abi: erc20Abi, functionName: "balanceOf", args: [account.address] });
  if (usdcBalance < usdcIn) throw new Error(`Taker holds ${formatUnits(usdcBalance, 6)} USDC, needs ${formatUnits(usdcIn, 6)}.`);
  const allowance = await client.readContract({ address: TOKENS.USDC, abi: erc20Abi, functionName: "allowance", args: [account.address, AQUA_SWAP_VM_ROUTER] });
  if (allowance < usdcIn) {
    const approveTx = await wallet.writeContract({ address: TOKENS.USDC, abi: erc20Abi, functionName: "approve", args: [AQUA_SWAP_VM_ROUTER, MAX_FILL_USDC * 10n] });
    await client.waitForTransactionReceipt({ hash: approveTx });
    info(`approve ${approveTx}`);
  }

  const minOut = (ao * (10_000n - slippageBps)) / 10_000n;
  info(`min out bound ${formatUnits(minOut, DECIMALS.WETH)} WETH (quote - ${slippageBps} bps)`);
  const swapData = SwapVMContract.encodeSwapCallData({
    order: strategy.order,
    tokenIn: new Address(TOKENS.USDC),
    tokenOut: new Address(TOKENS.WETH),
    amount: usdcIn,
    takerTraits: TakerTraits.default().with({ threshold: minOut }),
  });
  const swapTx = await wallet.sendTransaction({ to: AQUA_SWAP_VM_ROUTER, data: swapData.toString() as `0x${string}` });
  const receipt = await client.waitForTransactionReceipt({ hash: swapTx });
  info(`swap ${swapTx} status=${receipt.status} gas=${receipt.gasUsed}`);

  heading("4. Decode the settlement");
  for (const log of receipt.logs) {
    switch (topicOf(log)) {
      case TOPICS.pulled: { const e = parsePulled(log); info(`Pulled  ${e.token} ${e.amount}`); break; }
      case TOPICS.pushed: { const e = parsePushed(log); info(`Pushed  ${e.token} ${e.amount}`); break; }
      case TOPICS.swapped: { const e = parseSwapped(log); info(`Swapped in=${e.amountIn} out=${e.amountOut}`); break; }
      default: break;
    }
  }
}

main().catch((error) => { console.error(`\n${(error as Error).message}`); process.exitCode = 1; });
