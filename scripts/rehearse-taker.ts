/**
 * Fork acceptance test for POO-1066: ships a strategy from a stub vault with a small hot
 * buffer, then drives the REAL taker path against it, reconstructing the order from the
 * on-chain Shipped event rather than from anything we kept in memory.
 *
 * This is the rehearsal for the mainnet sequence at S3, including the fill that exceeds the
 * hot buffer and forces the JIT trace.
 *
 * Prereq: anvil --fork-url <arbitrum rpc> --port 8545
 * Run:    pnpm rehearse:taker
 */
import { spawn } from "node:child_process";
import { resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { AquaProtocolContract } from "@1inch/aqua-sdk";
import { Interaction } from "@1inch/sdk-core";
import { Address, AquaProgramBuilder, HexString, MakerTraits, Order } from "@1inch/swap-vm-sdk";
import { erc20Abi, keccak256, parseEther, parseUnits } from "viem";
import stubAdapterArtifact from "./fixtures/out/StubMaker.sol/StubAdapter.json" with { type: "json" };
import stubMakerArtifact from "./fixtures/out/StubMaker.sol/StubMaker.json" with { type: "json" };
import { AQUA_REGISTRY, AQUA_SWAP_VM_ROUTER, CHAINLINK_ETH_USD, DECIMALS, TOKENS } from "./lib/addresses.ts";
import { bandFromSpot, concentrateArgsFor } from "./lib/band.ts";
import { fund, makerAccount, takerAccount, testClient, transferFromWhale, walletFor } from "./lib/fork.ts";
import { fail, formatUnits, heading, info, pass } from "./lib/format.ts";
import { reconstructFromChain } from "./lib/reconstruct.ts";

const test = testClient();
const makerWallet = walletFor(makerAccount);
const aqua = new AquaProtocolContract(new Address(AQUA_REGISTRY));

let failures = 0;
function check(ok: boolean, message: string): void {
  if (ok) pass(message);
  else {
    fail(message);
    failures += 1;
  }
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

async function main(): Promise<void> {
  console.log("POO-1066 taker rehearsal on the Arbitrum fork");

  heading("1. Stand up a vault with a small hot buffer and a funded carry sleeve");
  await fund(makerAccount.address, { eth: parseEther("100") });
  await fund(takerAccount.address, { eth: parseEther("100"), weth: parseEther("10") });

  const deployHash = await makerWallet.deployContract({
    abi: stubMakerArtifact.abi,
    bytecode: stubMakerArtifact.bytecode.object as `0x${string}`,
    args: [AQUA_SWAP_VM_ROUTER, AQUA_REGISTRY],
  });
  const vault = (await test.waitForTransactionReceipt({ hash: deployHash })).contractAddress;
  if (!vault) throw new Error("vault deploy produced no address");

  const adapterHash = await makerWallet.deployContract({
    abi: stubAdapterArtifact.abi,
    bytecode: stubAdapterArtifact.bytecode.object as `0x${string}`,
    args: [vault, TOKENS.USDC],
  });
  const adapter = (await test.waitForTransactionReceipt({ hash: adapterHash })).contractAddress;
  if (!adapter) throw new Error("adapter deploy produced no address");

  let hash = await makerWallet.writeContract({
    address: vault,
    abi: stubMakerArtifact.abi,
    functionName: "setAdapter",
    args: [adapter],
  });
  await test.waitForTransactionReceipt({ hash });

  const sleeve = parseUnits("2000", DECIMALS.USDC);
  const hotBuffer = parseUnits("100", DECIMALS.USDC);
  await transferFromWhale(TOKENS.USDC, vault, hotBuffer);
  await transferFromWhale(TOKENS.USDC, adapter, sleeve - hotBuffer);

  hash = await makerWallet.writeContract({
    address: vault,
    abi: stubMakerArtifact.abi,
    functionName: "approveAqua",
    args: [TOKENS.USDC, 2n ** 255n],
  });
  await test.waitForTransactionReceipt({ hash });
  info(`vault ${vault} holds ${formatUnits(hotBuffer, DECIMALS.USDC)} USDC, adapter holds the rest`);

  heading("2. Ship the demo band");
  const [, spotE8] = await test.readContract({
    address: CHAINLINK_ETH_USD,
    abi: CHAINLINK_ABI,
    functionName: "latestRoundData",
  });
  // Demo mandate: spot-0.3% .. spot-0.1%, close enough to market to fill without a crash.
  const band = bandFromSpot(spotE8, -30n, -10n);
  const blockNow = await test.getBlock();
  const program = new AquaProgramBuilder()
    .deadline({ deadline: blockNow.timestamp + 3n * 86_400n })
    .concentrateGrowLiquidity2D(concentrateArgsFor(band))
    .flatFeeAmountInXD({ fee: 8_000_000n }) // 80 bps at 1e9 = 100%
    .xycSwapXD()
    .salt({ salt: 900_001n })
    .build();

  const traits = MakerTraits.default().with({
    preTransferOutHook: new Interaction(Address.ZERO_ADDRESS, new HexString("0x01")),
  });
  const order = Order.new({ maker: new Address(vault), traits, program });
  const shipCall = aqua.ship({
    app: new Address(AQUA_SWAP_VM_ROUTER),
    strategy: order.encode(),
    amountsAndTokens: [
      { token: new Address(TOKENS.USDC), amount: sleeve },
      { token: new Address(TOKENS.WETH), amount: 0n },
    ],
  });
  hash = await makerWallet.writeContract({
    address: vault,
    abi: stubMakerArtifact.abi,
    functionName: "exec",
    args: [shipCall.to as `0x${string}`, shipCall.data as `0x${string}`],
  });
  await test.waitForTransactionReceipt({ hash });
  const strategyHash = keccak256(order.encode().toString() as `0x${string}`);
  info(`shipped ${strategyHash}`);
  info(`band $${(Number(band.lowE8) / 1e8).toFixed(2)} .. $${(Number(band.highE8) / 1e8).toFixed(2)}`);

  heading("3. Reconstruct from chain, exactly as the taker does");
  const reconstructed = await reconstructFromChain(test as never, strategyHash, {
    searchBlocks: 5_000n,
    chunk: 5_000n,
  });
  check(
    reconstructed.order.encode().toString().toLowerCase() === order.encode().toString().toLowerCase(),
    "the order rebuilt from the Shipped event is byte-identical to the one we shipped",
  );
  check(
    reconstructed.maker.toLowerCase() === vault.toLowerCase(),
    "the reconstructed maker is the vault",
  );
  info("decoded straight from chain:");
  for (const line of reconstructed.instructions) info(`  ${line}`);

  heading("4. Small fill (inside the hot buffer)");
  const small = await runTaker(vault, strategyHash, "0.01");
  check(small.settled, "small fill settled");
  check(small.jitDelta === 0n, "  no JIT top-up: it fit inside the hot buffer");

  heading("5. Large fill (exceeds the hot buffer, forces the JIT trace)");
  const big = await runTaker(vault, strategyHash, "0.5");
  check(big.settled, "large fill settled in ONE transaction");
  check(big.jitDelta > 0n, "  JIT PATH HIT: the vault unparked from the carry sleeve mid-settlement");
  info(`unparked on that fill: ${formatUnits(big.jitDelta, DECIMALS.USDC)} USDC`);

  const adapterLeft = await test.readContract({
    address: TOKENS.USDC,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [adapter],
  });
  info(`carry sleeve remaining: ${formatUnits(adapterLeft, DECIMALS.USDC)} USDC`);
  check(
    adapterLeft < sleeve - hotBuffer,
    "capital left the carry sleeve only at the instant it was needed",
  );

  heading("Result");
  console.log(
    failures === 0
      ? "  TAKER REHEARSAL GREEN: reconstruct -> quote -> fill -> JIT fill, all from chain data"
      : `  ${failures} CHECK(S) FAILED`,
  );
  if (failures > 0) process.exitCode = 1;
  console.log(`\nStrategy used: ${strategyHash}`);
  console.log(`Vault: ${vault}   Adapter: ${adapter}`);
}

/**
 * Runs the REAL taker as a subprocess, so this rehearses `pnpm taker` itself rather than a
 * reimplementation of it. Effects are measured on chain afterwards instead of trusting the
 * script's own log lines.
 */
async function runTaker(
  vault: `0x${string}`,
  strategyHash: `0x${string}`,
  size: string,
): Promise<{ settled: boolean; jitDelta: bigint }> {
  const readTakerUsdc = () =>
    test.readContract({
      address: TOKENS.USDC,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [takerAccount.address],
    });
  const readJit = () =>
    test.readContract({
      address: vault,
      abi: stubMakerArtifact.abi,
      functionName: "jitUnparked",
    }) as Promise<bigint>;

  const usdcBefore = await readTakerUsdc();
  const jitBefore = await readJit();

  await new Promise<void>((resolve, reject) => {
    const child = spawn(
      "npx",
      [
        "tsx",
        "scripts/taker.ts",
        "--strategy",
        strategyHash,
        "--size",
        size,
        "--network",
        "fork",
        "--mandate",
        "demo",
      ],
      {
        cwd: resolvePath(fileURLToPath(import.meta.url), "../.."),
        stdio: "inherit",
        env: {
          ...process.env,
          // Anvil's second dev account, the same taker the rest of the rehearsal funds.
          TAKER_BOT_PRIVATE_KEY:
            "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
        },
      },
    );
    child.on("error", reject);
    child.on("close", (code) =>
      code === 0 ? resolve() : reject(new Error(`taker exited with code ${code}`)),
    );
  });

  const usdcAfter = await readTakerUsdc();
  const jitAfter = await readJit();
  return { settled: usdcAfter > usdcBefore, jitDelta: jitAfter - jitBefore };
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
