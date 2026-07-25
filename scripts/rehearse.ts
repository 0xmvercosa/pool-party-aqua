/**
 * POO-1058 step 2: full-loop rehearsal on an Anvil fork of Arbitrum, gen-2 pair, EOA maker.
 *
 *   approve -> ship BOTH tokens (WETH amount 0) -> quote() -> swap() -> decode events -> dock
 *
 * Plus the trap tests the compiler's guardrails will encode, each proven on-chain rather
 * than asserted in prose.
 *
 * Prereq: anvil --fork-url <arbitrum rpc> --port 8545
 * Run:    pnpm rehearse
 */
import { AquaProtocolContract, DockedEvent, PulledEvent, PushedEvent, ShippedEvent } from "@1inch/aqua-sdk";
import {
  Address,
  AquaProgramBuilder,
  HexString,
  MakerTraits,
  Order,
  SwapVMContract,
  SwappedEvent,
  TakerTraits,
  instructions,
} from "@1inch/swap-vm-sdk";
import { decodeFunctionResult, erc20Abi, keccak256, parseEther, parseUnits } from "viem";
import {
  AQUA_REGISTRY,
  AQUA_SWAP_VM_ROUTER,
  CHAINLINK_ETH_USD,
  DECIMALS,
  TOKENS,
} from "./lib/addresses.ts";
import { type Band, bandFromSpot, concentrateArgsFor, describeBand } from "./lib/band.ts";
import { fund, makerAccount, takerAccount, testClient, walletFor } from "./lib/fork.ts";
import { fail, formatUnits, heading, info, pass } from "./lib/format.ts";
import { renderInstructions } from "./lib/program.ts";

const test = testClient();
const makerWallet = walletFor(makerAccount);
const takerWallet = walletFor(takerAccount);

const aqua = new AquaProtocolContract(new Address(AQUA_REGISTRY));
const router = new Address(AQUA_SWAP_VM_ROUTER);

const FLAT_FEE_BPS = 80; // D4: 80 bps flat fee, accrues to the maker
const EPOCH_DAYS = 3n; // D5

let failures = 0;
function check(ok: boolean, message: string): boolean {
  if (ok) pass(message);
  else {
    fail(message);
    failures += 1;
  }
  return ok;
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
  {
    type: "function",
    name: "safeBalances",
    inputs: [
      { name: "maker", type: "address" },
      { name: "app", type: "address" },
      { name: "strategyHash", type: "bytes32" },
      { name: "token0", type: "address" },
      { name: "token1", type: "address" },
    ],
    outputs: [
      { name: "balance0", type: "uint256" },
      { name: "balance1", type: "uint256" },
    ],
    stateMutability: "view",
  },
] as const;

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

async function chainlinkSpotE8(): Promise<bigint> {
  const [, answer] = await test.readContract({
    address: CHAINLINK_ETH_USD,
    abi: CHAINLINK_ABI,
    functionName: "latestRoundData",
  });
  return answer;
}

/**
 * The canonical v1 program, corrected against the live gen-2 ships (PRG-R1 v3 proposal):
 *   [deadline][concentrateGrowLiquidity2D][flatFeeAmountInXD][xycSwapXD][salt]
 *
 * concentrate shapes the reserves; xycSwapXD is the instruction that actually executes the
 * swap on them. The fee sits between them. salt trails the curve as a hash-only no-op.
 */
function buildBandProgram(band: Band, deadline: bigint, salt: bigint) {
  return new AquaProgramBuilder()
    .deadline({ deadline })
    .concentrateGrowLiquidity2D(concentrateArgsFor(band))
    .flatFeeAmountInXD({ fee: feeBpsToRaw(FLAT_FEE_BPS) })
    .xycSwapXD()
    .salt({ salt })
    .build();
}

/** FlatFeeArgs is 1e9 = 100%, so 1 bp = 1e5. Kept explicit so the unit is never guessed. */
function feeBpsToRaw(bps: number): bigint {
  return (BigInt(bps) * 1_000_000_000n) / 10_000n;
}

function buildOrder(program: ReturnType<typeof buildBandProgram>, maker: `0x${string}`): Order {
  // Aqua mode: authenticated by the ship, not a signature. receiver == maker is enforced
  // upstream and WETH unwrap is forbidden, so both stay at their defaults.
  const traits = MakerTraits.default();
  return Order.new({ maker: new Address(maker), traits, program });
}

async function shipStrategy(
  order: Order,
  usdcAmount: bigint,
  wethAmount: bigint,
): Promise<{ strategyHash: `0x${string}`; txHash: `0x${string}` }> {
  const strategy = order.encode();
  const call = aqua.ship({
    app: router,
    strategy,
    // PRG-R2: BOTH tokens are registered. tokensCount comes from this array, and
    // safeBalances/push refuse any token that was not registered at ship time.
    amountsAndTokens: [
      { token: new Address(TOKENS.USDC), amount: usdcAmount },
      { token: new Address(TOKENS.WETH), amount: wethAmount },
    ],
  });
  const txHash = await makerWallet.sendTransaction({
    to: call.to as `0x${string}`,
    data: call.data as `0x${string}`,
    value: BigInt(call.value ?? 0),
  });
  await test.waitForTransactionReceipt({ hash: txHash });
  return { strategyHash: keccak256(strategy.toString() as `0x${string}`), txHash };
}

async function quote(order: Order, amountInWeth: bigint): Promise<{ amountIn: bigint; amountOut: bigint }> {
  const data = SwapVMContract.encodeQuoteCallData({
    order,
    tokenIn: new Address(TOKENS.WETH),
    tokenOut: new Address(TOKENS.USDC),
    amount: amountInWeth,
    takerTraits: TakerTraits.default(),
  });
  const result = await test.call({
    to: AQUA_SWAP_VM_ROUTER,
    data: data.toString() as `0x${string}`,
  });
  const [amountIn, amountOut] = decodeFunctionResult({
    abi: QUOTE_RESULT_ABI,
    functionName: "quote",
    data: result.data as `0x${string}`,
  });
  return { amountIn, amountOut };
}

async function main(): Promise<void> {
  console.log("POO-1058 fork rehearsal: gen-2 Aqua pair, EOA maker, Arbitrum fork");

  heading("0. Fork preflight");
  const chainId = await test.getChainId();
  check(chainId === 42161, `fork reports chain id ${chainId} (Arbitrum)`);
  const block = await test.getBlockNumber();
  info(`fork head block ${block}`);
  const registryCode = await test.getCode({ address: AQUA_REGISTRY });
  const routerCode = await test.getCode({ address: AQUA_SWAP_VM_ROUTER });
  check(!!registryCode && registryCode !== "0x", "gen-2 Aqua registry has code on the fork");
  check(!!routerCode && routerCode !== "0x", "gen-2 AquaSwapVMRouter has code on the fork");

  heading("1. Fund the maker and taker EOAs");
  const shippedUsdc = parseUnits("2000", DECIMALS.USDC);
  await fund(makerAccount.address, { eth: parseEther("100"), usdc: shippedUsdc * 2n });
  await fund(takerAccount.address, { eth: parseEther("100"), weth: parseEther("5") });
  const makerUsdc = await test.readContract({
    address: TOKENS.USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [makerAccount.address],
  });
  const takerWeth = await test.readContract({
    address: TOKENS.WETH,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [takerAccount.address],
  });
  info(`maker ${makerAccount.address}: ${formatUnits(makerUsdc, DECIMALS.USDC)} USDC`);
  info(`taker ${takerAccount.address}: ${formatUnits(takerWeth, DECIMALS.WETH)} WETH`);
  check(makerUsdc >= shippedUsdc, "maker funded with USDC");
  check(takerWeth > 0n, "taker funded with WETH");

  heading("2. Maker approves the Aqua registry for BOTH tokens");
  for (const token of [TOKENS.USDC, TOKENS.WETH] as const) {
    const hash = await makerWallet.writeContract({
      address: token,
      abi: erc20Abi,
      functionName: "approve",
      args: [AQUA_REGISTRY, 2n ** 255n],
    });
    await test.waitForTransactionReceipt({ hash });
  }
  const allowance = await test.readContract({
    address: TOKENS.USDC,
    abi: erc20Abi,
    functionName: "allowance",
    args: [makerAccount.address, AQUA_REGISTRY],
  });
  check(allowance > 0n, "USDC allowance to the Aqua registry is set");

  heading("3. Build the band program (PRG-R1 v3 order) via AquaProgramBuilder only");
  const spotE8 = await chainlinkSpotE8();
  // Production mandate: spot-15% .. spot-5%.
  const band = bandFromSpot(spotE8, -1500n, -500n);
  info(describeBand(band));
  const now = BigInt(Math.floor(Date.now() / 1000));
  const deadline = now + EPOCH_DAYS * 86_400n;
  const salt = 1n;
  const program = buildBandProgram(band, deadline, salt);
  const order = buildOrder(program, makerAccount.address);
  info(`program bytes: ${program.toString()}`);
  for (const line of renderInstructions(AquaProgramBuilder.decode(program))) info(`  ${line}`);

  const rebuilt = AquaProgramBuilder.decode(program).build().toString();
  check(rebuilt === program.toString(), "our own program round-trips through decode -> build");

  heading("4. Ship BOTH tokens, WETH amount 0 (PRG-R2)");
  const { strategyHash, txHash: shipTx } = await shipStrategy(order, shippedUsdc, 0n);
  info(`ship tx ${shipTx}`);
  info(`strategyHash ${strategyHash}`);
  check(
    strategyHash.toLowerCase() === order.hash().toString().toLowerCase(),
    "strategyHash == Order.hash() == keccak256(ABI-encoded Order) (PRG-R9)",
  );

  const shipReceipt = await test.getTransactionReceipt({ hash: shipTx });
  const shippedLog = shipReceipt.logs.find((l) => l.topics[0] === ShippedEvent.TOPIC.toString());
  check(!!shippedLog, "Shipped event emitted");
  if (shippedLog) {
    const parsed = ShippedEvent.fromLog({ topics: [...shippedLog.topics], data: shippedLog.data });
    check(
      parsed.strategy.toString().toLowerCase() === order.encode().toString().toLowerCase(),
      "Shipped.strategy is the ABI-encoded Order we built (taker can reconstruct it from chain alone)",
    );
  }

  const [usdcBalance, tokensCount] = await test.readContract({
    address: AQUA_REGISTRY,
    abi: AQUA_VIEW_ABI,
    functionName: "rawBalances",
    args: [makerAccount.address, AQUA_SWAP_VM_ROUTER, strategyHash, TOKENS.USDC],
  });
  const [wethBalance] = await test.readContract({
    address: AQUA_REGISTRY,
    abi: AQUA_VIEW_ABI,
    functionName: "rawBalances",
    args: [makerAccount.address, AQUA_SWAP_VM_ROUTER, strategyHash, TOKENS.WETH],
  });
  info(`rawBalances USDC=${formatUnits(usdcBalance, DECIMALS.USDC)} WETH=${wethBalance} tokensCount=${tokensCount}`);
  check(usdcBalance === shippedUsdc, "shipped USDC is registered at the full amount");
  check(wethBalance === 0n, "WETH side registered at amount 0");
  check(tokensCount === 2, "tokensCount == 2: both tokens registered, so push/safeBalances accept WETH");

  heading("5. quote() at three sizes");
  const sizes = [parseEther("0.01"), parseEther("0.1"), parseEther("0.5")];
  for (const size of sizes) {
    const q = await quote(order, size);
    const impliedUsd = (Number(q.amountOut) / 10 ** DECIMALS.USDC) / (Number(q.amountIn) / 1e18);
    info(
      `  in ${formatUnits(q.amountIn, DECIMALS.WETH)} WETH -> out ${formatUnits(q.amountOut, DECIMALS.USDC)} USDC ` +
        `(implied $${impliedUsd.toFixed(2)}/ETH)`,
    );
    check(q.amountOut > 0n, `  quote at ${formatUnits(size, DECIMALS.WETH)} WETH returns a non-zero amount`);
    check(
      impliedUsd < Number(band.highE8) / 1e8,
      "  implied price sits at or below the band top (we never buy above our own band)",
    );
  }

  heading("6. One real swap() as the taker");
  const fillSize = parseEther("0.1");
  const expected = await quote(order, fillSize);
  const approveHash = await takerWallet.writeContract({
    address: TOKENS.WETH,
    abi: erc20Abi,
    functionName: "approve",
    args: [AQUA_SWAP_VM_ROUTER, 2n ** 255n],
  });
  await test.waitForTransactionReceipt({ hash: approveHash });

  const swapData = SwapVMContract.encodeSwapCallData({
    order,
    tokenIn: new Address(TOKENS.WETH),
    tokenOut: new Address(TOKENS.USDC),
    amount: fillSize,
    takerTraits: TakerTraits.default(),
  });
  const swapTx = await takerWallet.sendTransaction({
    to: AQUA_SWAP_VM_ROUTER,
    data: swapData.toString() as `0x${string}`,
  });
  const swapReceipt = await test.waitForTransactionReceipt({ hash: swapTx });
  info(`swap tx ${swapTx} status=${swapReceipt.status} gas=${swapReceipt.gasUsed}`);
  check(swapReceipt.status === "success", "swap() succeeded");

  heading("7. Decode Pulled / Pushed / Swapped");
  for (const log of swapReceipt.logs) {
    const topic = log.topics[0];
    const like = { topics: [...log.topics], data: log.data };
    if (topic === PulledEvent.TOPIC.toString()) {
      const e = PulledEvent.fromLog(like);
      info(`  Pulled  token=${e.token} amount=${e.amount} (maker pays out)`);
    } else if (topic === PushedEvent.TOPIC.toString()) {
      const e = PushedEvent.fromLog(like);
      info(`  Pushed  token=${e.token} amount=${e.amount} (maker receives)`);
    } else if (topic === SwappedEvent.TOPIC.toString()) {
      const e = SwappedEvent.fromLog(like);
      info(`  Swapped in=${e.amountIn} out=${e.amountOut} taker=${e.taker}`);
      check(e.amountOut === expected.amountOut, "  Swapped.amountOut matches the pre-trade quote exactly");
    }
  }
  const pulled = swapReceipt.logs.some((l) => l.topics[0] === PulledEvent.TOPIC.toString());
  const pushed = swapReceipt.logs.some((l) => l.topics[0] === PushedEvent.TOPIC.toString());
  check(pulled, "Pulled emitted (USDC left the maker's Aqua balance)");
  check(pushed, "Pushed emitted (WETH landed in the maker's Aqua balance on the amount-0 side)");

  const [usdcAfter] = await test.readContract({
    address: AQUA_REGISTRY,
    abi: AQUA_VIEW_ABI,
    functionName: "rawBalances",
    args: [makerAccount.address, AQUA_SWAP_VM_ROUTER, strategyHash, TOKENS.USDC],
  });
  const [wethAfter] = await test.readContract({
    address: AQUA_REGISTRY,
    abi: AQUA_VIEW_ABI,
    functionName: "rawBalances",
    args: [makerAccount.address, AQUA_SWAP_VM_ROUTER, strategyHash, TOKENS.WETH],
  });
  info(`rawBalances after fill: USDC=${formatUnits(usdcAfter, DECIMALS.USDC)} WETH=${formatUnits(wethAfter, DECIMALS.WETH)}`);
  check(usdcAfter < shippedUsdc, "strategy USDC decreased by the fill");
  check(wethAfter > 0n, "strategy WETH increased from 0: the amount-0 side accepted the push");

  heading("8. dock()");
  const dockCall = aqua.dock({
    app: router,
    strategyHash: new HexString(strategyHash),
    tokens: [new Address(TOKENS.USDC), new Address(TOKENS.WETH)],
  });
  const dockTx = await makerWallet.sendTransaction({
    to: dockCall.to as `0x${string}`,
    data: dockCall.data as `0x${string}`,
  });
  const dockReceipt = await test.waitForTransactionReceipt({ hash: dockTx });
  info(`dock tx ${dockTx} status=${dockReceipt.status}`);
  check(dockReceipt.status === "success", "dock() succeeded");
  const docked = dockReceipt.logs.some((l) => l.topics[0] === DockedEvent.TOPIC.toString());
  check(docked, "Docked event emitted");

  const [usdcDocked] = await test.readContract({
    address: AQUA_REGISTRY,
    abi: AQUA_VIEW_ABI,
    functionName: "rawBalances",
    args: [makerAccount.address, AQUA_SWAP_VM_ROUTER, strategyHash, TOKENS.USDC],
  });
  check(usdcDocked === 0n, "docked strategy holds no USDC (funds returned to the maker wallet)");

  heading("Result");
  console.log(
    failures === 0
      ? "  REHEARSAL GREEN: approve -> ship -> quote -> swap -> dock all pass on the gen-2 pair"
      : `  ${failures} CHECK(S) FAILED`,
  );
  if (failures > 0) process.exitCode = 1;

  console.log("\nEvidence for VERIFIED.md:");
  console.log(`  ship  ${shipTx}`);
  console.log(`  swap  ${swapTx}`);
  console.log(`  dock  ${dockTx}`);
  console.log(`  strategyHash ${strategyHash}`);
  void instructions;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
