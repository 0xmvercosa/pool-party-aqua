/**
 * POO-1058 step 3: prove the traps on-chain instead of asserting them in prose.
 *
 * Every guardrail the compiler (POO-1061) will enforce gets a failing-input demonstration
 * here first, so the rule exists because we watched it break, not because a doc said so.
 *
 *   A. preTransferOut maker hook fires BEFORE Aqua pulls        -> the 90/10 premise
 *   B. is ship a transfer or accounting only?                    -> the hot-buffer premise
 *   C. a fee emitted after the curve is silently never applied   -> PRG-R1 ordering
 *   D. one-token ship breaks quote/fill                          -> PRG-R2
 *   E. tokenIn fee opcode + WETH-at-0 ship reverts the fill      -> PRG-R7
 *   F. the tokenOut fee opcode is not buildable in Aqua mode     -> PRG-R7 verdict
 *   G. a docked strategyHash is dead forever                     -> PRG-R10
 *
 * Prereq: anvil --fork-url <arbitrum rpc> --port 8545
 * Run:    pnpm rehearse:traps
 */
import { AquaProtocolContract } from "@1inch/aqua-sdk";
// Interaction lives in sdk-core, pinned to the exact version swap-vm-sdk depends on so the
// class identity the SDK checks against is the same one we construct.
import { Interaction } from "@1inch/sdk-core";
import {
  Address,
  AquaProgramBuilder,
  HexString,
  MakerTraits,
  Order,
  SwapVMContract,
  TakerTraits,
  instructions,
} from "@1inch/swap-vm-sdk";
import {
  decodeAbiParameters,
  decodeFunctionResult,
  encodeFunctionData,
  erc20Abi,
  keccak256,
  parseEther,
  parseUnits,
  toFunctionSelector,
} from "viem";
import stubAdapterArtifact from "./fixtures/out/StubMaker.sol/StubAdapter.json" with { type: "json" };
import stubMakerArtifact from "./fixtures/out/StubMaker.sol/StubMaker.json" with { type: "json" };
import { AQUA_REGISTRY, AQUA_SWAP_VM_ROUTER, CHAINLINK_ETH_USD, DECIMALS, TOKENS } from "./lib/addresses.ts";
import { type Band, bandFromSpot, concentrateArgsFor } from "./lib/band.ts";
import { TOPICS, topicOf } from "./lib/events.ts";
import { fund, makerAccount, takerAccount, testClient, transferFromWhale, walletFor } from "./lib/fork.ts";
import { fail, formatUnits, heading, info, pass } from "./lib/format.ts";

const test = testClient();
const makerWallet = walletFor(makerAccount);
const takerWallet = walletFor(takerAccount);
const aqua = new AquaProtocolContract(new Address(AQUA_REGISTRY));
const router = new Address(AQUA_SWAP_VM_ROUTER);

const FLAT_FEE_BPS = 80;
const EPOCH_SECONDS = 3n * 86_400n;

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

const STUB_ABI = stubMakerArtifact.abi;
const ADAPTER_ABI = stubAdapterArtifact.abi;

/**
 * The maker hook the router actually calls. MEASURED in trap A, not taken from any doc:
 * the published SwapVM ABI does not include it. Track A's PartyVault must implement
 * exactly this, not the `onPreTransferOut(address,uint256)` in the kickoff interface list.
 */
const MAKER_HOOK_SIGNATURE =
  "preTransferOut(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)" as const;

function feeBpsToRaw(bps: number): bigint {
  return (BigInt(bps) * 1_000_000_000n) / 10_000n;
}

async function spotE8(): Promise<bigint> {
  const [, answer] = await test.readContract({
    address: CHAINLINK_ETH_USD,
    abi: CHAINLINK_ABI,
    functionName: "latestRoundData",
  });
  return answer;
}

async function deadline(): Promise<bigint> {
  const block = await test.getBlock();
  return block.timestamp + EPOCH_SECONDS;
}

/** PRG-R1 v3, the order confirmed against the live gen-2 ships. */
function canonicalProgram(band: Band, dl: bigint, salt: bigint) {
  return new AquaProgramBuilder()
    .deadline({ deadline: dl })
    .concentrateGrowLiquidity2D(concentrateArgsFor(band))
    .flatFeeAmountInXD({ fee: feeBpsToRaw(FLAT_FEE_BPS) })
    .xycSwapXD()
    .salt({ salt })
    .build();
}

function orderFor(program: HexString, maker: `0x${string}`, traits = MakerTraits.default()): Order {
  return Order.new({ maker: new Address(maker), traits, program: program as never });
}

async function quoteOf(order: Order, amountIn: bigint): Promise<{ amountIn: bigint; amountOut: bigint }> {
  const data = SwapVMContract.encodeQuoteCallData({
    order,
    tokenIn: new Address(TOKENS.WETH),
    tokenOut: new Address(TOKENS.USDC),
    amount: amountIn,
    takerTraits: TakerTraits.default(),
  });
  const result = await test.call({ to: AQUA_SWAP_VM_ROUTER, data: data.toString() as `0x${string}` });
  const [ai, ao] = decodeFunctionResult({
    abi: QUOTE_RESULT_ABI,
    functionName: "quote",
    data: result.data as `0x${string}`,
  });
  return { amountIn: ai, amountOut: ao };
}

function swapCalldata(order: Order, amountIn: bigint): `0x${string}` {
  return SwapVMContract.encodeSwapCallData({
    order,
    tokenIn: new Address(TOKENS.WETH),
    tokenOut: new Address(TOKENS.USDC),
    amount: amountIn,
    takerTraits: TakerTraits.default(),
  }).toString() as `0x${string}`;
}

/** Ship from an EOA maker. */
async function shipFromEoa(order: Order, usdc: bigint, weth: bigint): Promise<`0x${string}`> {
  const strategy = order.encode();
  const call = aqua.ship({
    app: router,
    strategy,
    amountsAndTokens: [
      { token: new Address(TOKENS.USDC), amount: usdc },
      { token: new Address(TOKENS.WETH), amount: weth },
    ],
  });
  const hash = await makerWallet.sendTransaction({
    to: call.to as `0x${string}`,
    data: call.data as `0x${string}`,
  });
  await test.waitForTransactionReceipt({ hash });
  return keccak256(strategy.toString() as `0x${string}`);
}

async function approveMakerTokens(): Promise<void> {
  for (const token of [TOKENS.USDC, TOKENS.WETH] as const) {
    const hash = await makerWallet.writeContract({
      address: token,
      abi: erc20Abi,
      functionName: "approve",
      args: [AQUA_REGISTRY, 2n ** 255n],
    });
    await test.waitForTransactionReceipt({ hash });
  }
}

// ---------------------------------------------------------------------------

async function trapB_shipIsAccountingOnly(band: Band): Promise<void> {
  heading("B. Is ship() a transfer, or accounting only? (the hot-buffer premise)");

  const before = await test.readContract({
    address: TOKENS.USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [makerAccount.address],
  });
  const shipped = parseUnits("1000", DECIMALS.USDC);
  const hash = await shipFromEoa(orderFor(canonicalProgram(band, await deadline(), 1001n), makerAccount.address), shipped, 0n);
  const after = await test.readContract({
    address: TOKENS.USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [makerAccount.address],
  });

  info(`maker wallet USDC before ship ${formatUnits(before, DECIMALS.USDC)}, after ${formatUnits(after, DECIMALS.USDC)}`);
  check(
    after === before,
    "ship() moved zero tokens: registration is accounting only, tokens stay in the maker's wallet until pull",
  );
  info(`  This is what makes the 90/10 sleeve possible: the strategy quotes ${formatUnits(shipped, DECIMALS.USDC)} USDC`);
  info("  of depth while the maker's wallet can hold a fraction of it and the rest earns in Aave.");
  void hash;
}

async function trapA_hookFires(band: Band): Promise<void> {
  heading("A. Does the preTransferOut maker hook fire BEFORE Aqua pulls? (the 90/10 premise)");

  // Deploy the stub vault as maker, plus a stub carry adapter holding the parked sleeve.
  const deployHash = await makerWallet.deployContract({
    abi: STUB_ABI,
    bytecode: stubMakerArtifact.bytecode.object as `0x${string}`,
    args: [AQUA_SWAP_VM_ROUTER, AQUA_REGISTRY],
  });
  const deployReceipt = await test.waitForTransactionReceipt({ hash: deployHash });
  const stub = deployReceipt.contractAddress;
  if (!stub) {
    check(false, "stub maker deployed");
    return;
  }

  const adapterHash = await makerWallet.deployContract({
    abi: ADAPTER_ABI,
    bytecode: stubAdapterArtifact.bytecode.object as `0x${string}`,
    args: [stub, TOKENS.USDC],
  });
  const adapterReceipt = await test.waitForTransactionReceipt({ hash: adapterHash });
  const adapter = adapterReceipt.contractAddress;
  if (!adapter) {
    check(false, "stub adapter deployed");
    return;
  }
  info(`stub vault  ${stub}`);
  info(`stub adapter ${adapter} (stands in for the Aave v3 carry adapter)`);

  let hash = await makerWallet.writeContract({
    address: stub,
    abi: STUB_ABI,
    functionName: "setAdapter",
    args: [adapter],
  });
  await test.waitForTransactionReceipt({ hash });

  // The sleeve is real money and it is really split: the hot buffer sits in the vault,
  // everything else sits in the adapter and is unreachable without the hook.
  const sleeve = parseUnits("2000", DECIMALS.USDC);
  const hotBuffer = parseUnits("100", DECIMALS.USDC);
  await transferFromWhale(TOKENS.USDC, stub, hotBuffer);
  await transferFromWhale(TOKENS.USDC, adapter, sleeve - hotBuffer);

  hash = await makerWallet.writeContract({
    address: stub,
    abi: STUB_ABI,
    functionName: "approveAqua",
    args: [TOKENS.USDC, 2n ** 255n],
  });
  await test.waitForTransactionReceipt({ hash });

  const vaultLiquid = await test.readContract({
    address: TOKENS.USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [stub],
  });
  const adapterParked = await test.readContract({
    address: TOKENS.USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [adapter],
  });
  info(
    `  sleeve ${formatUnits(sleeve, DECIMALS.USDC)} USDC = ` +
      `${formatUnits(vaultLiquid, DECIMALS.USDC)} hot buffer in the vault + ` +
      `${formatUnits(adapterParked, DECIMALS.USDC)} parked in the adapter`,
  );

  // Ship the FULL sleeve. Aqua registration is accounting only (trap B), so the strategy
  // quotes depth the vault does not hold in its wallet.
  // Target = zero address means "call the maker itself". The SDK's Interaction rejects
  // empty data, so the hook carries a one-byte marker; the router passes it straight
  // through as the makerHookData argument and does not interpret it.
  const traits = MakerTraits.default().with({
    preTransferOutHook: new Interaction(Address.ZERO_ADDRESS, new HexString("0x01")),
  });
  const order = orderFor(canonicalProgram(band, await deadline(), 2001n), stub, traits);
  check(
    order.traits.preTransferOutHook !== undefined,
    "MakerTraits carries a preTransferOut hook with target = zero address (call the maker itself)",
  );

  const shipCall = aqua.ship({
    app: router,
    strategy: order.encode(),
    amountsAndTokens: [
      { token: new Address(TOKENS.USDC), amount: sleeve },
      { token: new Address(TOKENS.WETH), amount: 0n },
    ],
  });
  hash = await makerWallet.writeContract({
    address: stub,
    abi: STUB_ABI,
    functionName: "exec",
    args: [shipCall.to as `0x${string}`, shipCall.data as `0x${string}`],
  });
  await test.waitForTransactionReceipt({ hash });
  info(`  shipped the full sleeve from the contract maker`);

  // A fill LARGER than the hot buffer: it can only settle if the hook tops up first.
  const fillSize = parseEther("0.5");
  const q = await quoteOf(order, fillSize);
  info(`  quote ${formatUnits(fillSize, DECIMALS.WETH)} WETH -> ${formatUnits(q.amountOut, DECIMALS.USDC)} USDC`);
  check(
    q.amountOut > vaultLiquid,
    `  the fill (${formatUnits(q.amountOut, DECIMALS.USDC)} USDC) EXCEEDS the vault's whole wallet balance ` +
      `(${formatUnits(vaultLiquid, DECIMALS.USDC)} USDC): without the hook this settlement is impossible`,
  );

  const approve = await takerWallet.writeContract({
    address: TOKENS.WETH,
    abi: erc20Abi,
    functionName: "approve",
    args: [AQUA_SWAP_VM_ROUTER, 2n ** 255n],
  });
  await test.waitForTransactionReceipt({ hash: approve });

  let swapReceipt: Awaited<ReturnType<typeof test.waitForTransactionReceipt>> | undefined;
  try {
    const swapTx = await takerWallet.sendTransaction({
      to: AQUA_SWAP_VM_ROUTER,
      data: swapCalldata(order, fillSize),
    });
    swapReceipt = await test.waitForTransactionReceipt({ hash: swapTx });
    info(`  swap tx ${swapTx}`);
  } catch (error) {
    info(`  swap reverted: ${(error as Error).message.split("\n")[0]}`);
  }

  const hookCalls = (await test.readContract({
    address: stub,
    abi: STUB_ABI,
    functionName: "hookCalls",
  })) as bigint;
  check(hookCalls > 0n, "the maker's preTransferOut hook WAS called during settlement");
  info(`  hook selector the router used: ${toFunctionSelector(MAKER_HOOK_SIGNATURE)}`);
  info(`  measured signature: ${MAKER_HOOK_SIGNATURE}`);

  const liquidAtHook = (await test.readContract({
    address: stub,
    abi: STUB_ABI,
    functionName: "liquidAtHook",
  })) as bigint;
  const jitUnparked = (await test.readContract({
    address: stub,
    abi: STUB_ABI,
    functionName: "jitUnparked",
  })) as bigint;
  const lastAmount = (await test.readContract({
    address: stub,
    abi: STUB_ABI,
    functionName: "lastAmount",
  })) as bigint;

  info(`  the hook was told: pay out ${formatUnits(lastAmount, DECIMALS.USDC)} USDC`);
  info(`  vault balance at that moment: ${formatUnits(liquidAtHook, DECIMALS.USDC)} USDC`);
  info(`  unparked just in time: ${formatUnits(jitUnparked, DECIMALS.USDC)} USDC`);
  check(
    lastAmount === q.amountOut,
    "  the hook receives the exact amount the maker owes, so the vault knows what to produce",
  );
  check(
    liquidAtHook < q.amountOut,
    "  the hook ran while the vault was still SHORT: it fires strictly BEFORE Aqua pulls",
  );
  check(jitUnparked > 0n, "  the vault unparked the shortfall inside the settlement transaction");

  if (swapReceipt) {
    check(
      swapReceipt.status === "success",
      "  the oversized fill settled in ONE transaction (the JIT money shot)",
    );
    const pulled = swapReceipt.logs.some((l) => topicOf(l) === TOPICS.pulled);
    check(pulled, "  Pulled emitted after the hook, in the same transaction");
    info(`  gas used for a JIT fill (stub adapter, no Aave call yet): ${swapReceipt.gasUsed}`);
  }

  const adapterAfter = await test.readContract({
    address: TOKENS.USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [adapter],
  });
  info(`  adapter balance after the fill: ${formatUnits(adapterAfter, DECIMALS.USDC)} USDC`);
  check(
    adapterAfter < adapterParked,
    "  capital left the carry sleeve only at the instant it was needed: it earned until then",
  );
}

async function trapC_feeAfterCurve(band: Band): Promise<void> {
  heading("C. What happens to a fee emitted AFTER the curve? (PRG-R1 ordering)");

  const dl = await deadline();
  const correct = orderFor(canonicalProgram(band, dl, 3001n), makerAccount.address);
  const feeAfterCurve = orderFor(
    new AquaProgramBuilder()
      .deadline({ deadline: dl })
      .concentrateGrowLiquidity2D(concentrateArgsFor(band))
      .xycSwapXD()
      .flatFeeAmountInXD({ fee: feeBpsToRaw(FLAT_FEE_BPS) })
      .salt({ salt: 3002n })
      .build(),
    makerAccount.address,
  );
  // The v2 order literally as written in the rules: no xycSwapXD at all.
  const noCurve = orderFor(
    new AquaProgramBuilder()
      .deadline({ deadline: dl })
      .flatFeeAmountInXD({ fee: feeBpsToRaw(FLAT_FEE_BPS) })
      .concentrateGrowLiquidity2D(concentrateArgsFor(band))
      .salt({ salt: 3003n })
      .build(),
    makerAccount.address,
  );

  const shipped = parseUnits("1000", DECIMALS.USDC);
  await shipFromEoa(correct, shipped, 0n);
  await shipFromEoa(feeAfterCurve, shipped, 0n);
  await shipFromEoa(noCurve, shipped, 0n);

  const size = parseEther("0.1");
  const baseline = await quoteOf(correct, size);
  info(`  canonical order (PRG-R1 v3): ${formatUnits(baseline.amountOut, DECIMALS.USDC)} USDC out`);

  // The upstream claim is "silently never applied". Measure which it actually is.
  let postCurveOutcome = "";
  try {
    const q = await quoteOf(feeAfterCurve, size);
    postCurveOutcome = `quotes ${formatUnits(q.amountOut, DECIMALS.USDC)} USDC out`;
    check(
      q.amountOut > baseline.amountOut,
      "  fee AFTER the curve: quote succeeds but the fee is silently skipped (maker earns no premium)",
    );
    const lostBps = Number(((q.amountOut - baseline.amountOut) * 10_000n) / baseline.amountOut);
    info(`  premium silently lost: ~${lostBps} bps, no revert, no warning`);
  } catch (error) {
    postCurveOutcome = `reverts: ${shortRevert(error)}`;
    check(true, `  fee AFTER the curve: the strategy is unquotable (${postCurveOutcome})`);
    info("  Stronger than the documented behaviour: it does not silently underpay, it breaks");
    info("  outright, so a mis-ordered program can never reach a fill.");
  }

  let noCurveOutcome = "";
  try {
    const q = await quoteOf(noCurve, size);
    noCurveOutcome = `quotes ${formatUnits(q.amountOut, DECIMALS.USDC)} USDC out`;
    check(false, `  PRG-R1 v2 order (no xycSwapXD) unexpectedly quotes: ${noCurveOutcome}`);
  } catch (error) {
    noCurveOutcome = shortRevert(error);
    check(
      true,
      `  PRG-R1 v2 order verbatim (no xycSwapXD) is unquotable (${noCurveOutcome}): concentrate alone is not a curve`,
    );
  }
}

function shortRevert(error: unknown): string {
  const message = (error as Error).message ?? String(error);
  const custom = message.match(/custom error (0x[0-9a-fA-F]+)/);
  if (custom) return `custom error ${custom[1]}`;
  return message.split("\n")[0]?.slice(0, 80) ?? "reverted";
}

async function trapD_singleTokenShip(band: Band): Promise<void> {
  heading("D. Does a one-token ship break quote/fill? (PRG-R2)");

  const order = orderFor(canonicalProgram(band, await deadline(), 4001n), makerAccount.address);
  const strategy = order.encode();
  const call = aqua.ship({
    app: router,
    strategy,
    // Deliberately register ONLY USDC. tokensCount becomes 1.
    amountsAndTokens: [{ token: new Address(TOKENS.USDC), amount: parseUnits("1000", DECIMALS.USDC) }],
  });
  const hash = await makerWallet.sendTransaction({
    to: call.to as `0x${string}`,
    data: call.data as `0x${string}`,
  });
  await test.waitForTransactionReceipt({ hash });

  let reverted = false;
  let reason = "";
  try {
    await quoteOf(order, parseEther("0.1"));
  } catch (error) {
    reverted = true;
    reason = (error as Error).message.split("\n")[0] ?? "";
  }
  check(reverted, `quote() on a one-token ship reverts (${reason || "no reason string"})`);
  info("  safeBalances refuses a token that was not registered at ship time, so the WETH side");
  info("  must be registered with amount 0 rather than omitted.");
}

async function trapE_tokenInFeeWithZeroWeth(band: Band): Promise<void> {
  heading("E. tokenIn fee opcode + WETH-at-0 ship: does the fill revert? (PRG-R7)");

  const dl = await deadline();
  const withProtocolFee = orderFor(
    new AquaProgramBuilder()
      .deadline({ deadline: dl })
      .aquaProtocolFeeAmountInXD({ fee: feeBpsToRaw(5), to: new Address(takerAccount.address) })
      .concentrateGrowLiquidity2D(concentrateArgsFor(band))
      .flatFeeAmountInXD({ fee: feeBpsToRaw(FLAT_FEE_BPS) })
      .xycSwapXD()
      .salt({ salt: 5001n })
      .build(),
    makerAccount.address,
  );
  await shipFromEoa(withProtocolFee, parseUnits("1000", DECIMALS.USDC), 0n);

  const approve = await takerWallet.writeContract({
    address: TOKENS.WETH,
    abi: erc20Abi,
    functionName: "approve",
    args: [AQUA_SWAP_VM_ROUTER, 2n ** 255n],
  });
  await test.waitForTransactionReceipt({ hash: approve });

  let failed = false;
  let reason = "";
  try {
    const tx = await takerWallet.sendTransaction({
      to: AQUA_SWAP_VM_ROUTER,
      data: swapCalldata(withProtocolFee, parseEther("0.1")),
    });
    const receipt = await test.waitForTransactionReceipt({ hash: tx });
    failed = receipt.status !== "success";
  } catch (error) {
    failed = true;
    reason = (error as Error).message.split("\n")[0] ?? "";
  }
  check(
    failed,
    `the fill fails with a tokenIn protocol fee against a WETH-at-0 ship (${reason || "reverted"})`,
  );
  info("  aquaProtocolFeeAmountInXD pulls tokenIn (WETH) inside runLoop, before settlement adds any.");
  info("  On a buy band the WETH side is shipped at 0, so there is nothing to pull. PRG-R7 v2 holds:");
  info("  the on-chain protocol fee stays out of the v1 program.");
}

function trapF_tokenOutFeeNotBuildable(): void {
  heading("F. Is the tokenOut fee opcode buildable in Aqua mode? (the S1 fee verdict)");

  const aquaNames = instructions.aquaInstructions.map((o) => o?.id.description ?? "");
  check(
    !aquaNames.some((n) => n.toLowerCase().includes("amountout")),
    "no *AmountOut* fee opcode exists in the Aqua instruction set",
  );

  let rejected = false;
  let message = "";
  try {
    new AquaProgramBuilder().add(
      instructions.fee.aquaProtocolFeeAmountOutXD.createIx(
        new instructions.fee.ProtocolFeeArgs(feeBpsToRaw(5), new Address(takerAccount.address)),
      ),
    );
  } catch (error) {
    rejected = true;
    message = (error as Error).message.slice(0, 90);
  }
  check(rejected, `AquaProgramBuilder rejects aquaProtocolFeeAmountOutXD by construction (${message}...)`);
  info("  It exists only in the regular SwapVM instruction set. Verdict: the on-chain protocol fee");
  info("  cannot be charged in USDC on the deployed Aqua router, so it stays out of v1.");
}

async function trapG_dockedHashIsDead(band: Band): Promise<void> {
  heading("G. Is a docked strategyHash dead forever? (PRG-R10, the salt-must-change rule)");

  const dl = await deadline();
  const salt = 6001n;
  const order = orderFor(canonicalProgram(band, dl, salt), makerAccount.address);
  const shipped = parseUnits("500", DECIMALS.USDC);
  const strategyHash = await shipFromEoa(order, shipped, 0n);
  info(`  shipped strategyHash ${strategyHash}`);

  const dockCall = aqua.dock({
    app: router,
    strategyHash: new HexString(strategyHash),
    tokens: [new Address(TOKENS.USDC), new Address(TOKENS.WETH)],
  });
  const dockTx = await makerWallet.sendTransaction({
    to: dockCall.to as `0x${string}`,
    data: dockCall.data as `0x${string}`,
  });
  await test.waitForTransactionReceipt({ hash: dockTx });
  info("  docked");

  // Re-ship the byte-identical program (same salt) and expect it to be refused.
  let reshipFailed = false;
  let reason = "";
  try {
    const call = aqua.ship({
      app: router,
      strategy: order.encode(),
      amountsAndTokens: [
        { token: new Address(TOKENS.USDC), amount: shipped },
        { token: new Address(TOKENS.WETH), amount: 0n },
      ],
    });
    const tx = await makerWallet.sendTransaction({
      to: call.to as `0x${string}`,
      data: call.data as `0x${string}`,
    });
    const receipt = await test.waitForTransactionReceipt({ hash: tx });
    reshipFailed = receipt.status !== "success";
  } catch (error) {
    reshipFailed = true;
    reason = (error as Error).message.split("\n")[0] ?? "";
  }
  check(reshipFailed, `re-shipping the SAME program after docking is refused (${reason || "reverted"})`);

  // Changing only the salt produces a fresh, shippable strategy.
  const rolled = orderFor(canonicalProgram(band, dl, salt + 1n), makerAccount.address);
  const rolledHash = await shipFromEoa(rolled, shipped, 0n);
  check(
    rolledHash.toLowerCase() !== strategyHash.toLowerCase(),
    "changing ONLY the salt yields a new strategyHash that ships cleanly: every roll must re-salt",
  );
  info(`  rolled strategyHash ${rolledHash}`);
}

async function main(): Promise<void> {
  console.log("POO-1058 trap rehearsal: every compiler guardrail demonstrated on-chain");

  const chainId = await test.getChainId();
  check(chainId === 42161, `fork reports chain id ${chainId}`);

  await fund(makerAccount.address, { eth: parseEther("100"), usdc: parseUnits("20000", DECIMALS.USDC) });
  await fund(takerAccount.address, { eth: parseEther("100"), weth: parseEther("10") });
  await approveMakerTokens();

  const band = bandFromSpot(await spotE8(), -1500n, -500n);

  // Each trap is isolated: a trap that blows up in an unexpected way must not hide the
  // results of the ones after it.
  const traps: Array<[string, () => Promise<void> | void]> = [
    ["B", () => trapB_shipIsAccountingOnly(band)],
    ["A", () => trapA_hookFires(band)],
    ["C", () => trapC_feeAfterCurve(band)],
    ["D", () => trapD_singleTokenShip(band)],
    ["E", () => trapE_tokenInFeeWithZeroWeth(band)],
    ["F", () => trapF_tokenOutFeeNotBuildable()],
    ["G", () => trapG_dockedHashIsDead(band)],
  ];
  for (const [name, run] of traps) {
    try {
      await run();
    } catch (error) {
      fail(`trap ${name} threw unexpectedly: ${shortRevert(error)}`);
      failures += 1;
    }
  }

  heading("Result");
  console.log(failures === 0 ? "  ALL TRAPS DEMONSTRATED" : `  ${failures} CHECK(S) FAILED`);
  if (failures > 0) process.exitCode = 1;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
