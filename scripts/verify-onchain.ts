/**
 * POO-1058 step 1: read-only mainnet ground truth.
 *
 * Closes three of the four VERIFIED.md checkboxes without sending a single transaction:
 *   - builder round-trip vs the live gen-2 ships (does our SDK mirror the deployed opcode array?)
 *   - is a tokenOut protocol-fee variant reachable through AquaProgramBuilder?
 *   - are the gen-2 makers EOAs?
 *
 * The fourth (maker hook firing) needs execution and lives in scripts/rehearse.ts.
 *
 * Run: pnpm verify:onchain
 */
import { ShippedEvent } from "@1inch/aqua-sdk";
import { keccak256 } from "viem";
import {
  AQUA_REGISTRY,
  AQUA_SWAP_VM_ROUTER,
  DEAD_GEN1_REGISTRY,
  DEAD_GEN1_ROUTER,
  REFERENCE_SHIP_TX,
  GEN2_FIRST_ACTIVITY_BLOCK,
} from "./lib/addresses.ts";
import { mainnetClient } from "./lib/clients.ts";
import { fail, heading, info, pass } from "./lib/format.ts";
import {
  AQUA_INSTRUCTION_SET,
  EMPTY_SLOT,
  aquaOpcodeTable,
  decodeProgram,
  decodeShipBytes,
  renderInstructions,
} from "./lib/program.ts";

const client = mainnetClient();

const AQUA_GETTER_ABI = [
  { type: "function", name: "AQUA", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" },
] as const;

/**
 * Shipped(address,address,bytes32,bytes), all non-indexed. Same shape as the aqua-sdk's
 * AQUA_ABI entry, spelled out here so viem infers concrete log types.
 */
const SHIPPED_EVENT = {
  type: "event",
  name: "Shipped",
  anonymous: false,
  inputs: [
    { name: "maker", type: "address", indexed: false },
    { name: "app", type: "address", indexed: false },
    { name: "strategyHash", type: "bytes32", indexed: false },
    { name: "strategy", type: "bytes", indexed: false },
  ],
} as const;

const EIP712_ABI = [
  {
    type: "function",
    name: "eip712Domain",
    inputs: [],
    outputs: [
      { name: "fields", type: "bytes1" },
      { name: "name", type: "string" },
      { name: "version", type: "string" },
      { name: "chainId", type: "uint256" },
      { name: "verifyingContract", type: "address" },
      { name: "salt", type: "bytes32" },
      { name: "extensions", type: "uint256[]" },
    ],
    stateMutability: "view",
  },
] as const;

let failures = 0;
function check(ok: boolean, message: string): boolean {
  if (ok) pass(message);
  else {
    fail(message);
    failures += 1;
  }
  return ok;
}

async function verifyPairs(): Promise<void> {
  heading("1. Generation pairing (each router's AQUA() points at its own registry)");

  const gen2Registry = await client.readContract({
    address: AQUA_SWAP_VM_ROUTER,
    abi: AQUA_GETTER_ABI,
    functionName: "AQUA",
  });
  check(
    gen2Registry.toLowerCase() === AQUA_REGISTRY.toLowerCase(),
    `gen-2 router AQUA() = ${gen2Registry} (expected ${AQUA_REGISTRY})`,
  );

  const gen1Registry = await client.readContract({
    address: DEAD_GEN1_ROUTER,
    abi: AQUA_GETTER_ABI,
    functionName: "AQUA",
  });
  check(
    gen1Registry.toLowerCase() === DEAD_GEN1_REGISTRY.toLowerCase(),
    `gen-1 router AQUA() = ${gen1Registry} (dead generation, never used by us)`,
  );
  check(
    gen1Registry.toLowerCase() !== gen2Registry.toLowerCase(),
    "the two generations are disjoint deployments, not an address discrepancy",
  );

  const domain = await client.readContract({
    address: AQUA_SWAP_VM_ROUTER,
    abi: EIP712_ABI,
    functionName: "eip712Domain",
  });
  const [, name, version] = domain;
  info(`gen-2 EIP-712 domain: name="${name}" version="${version}"`);
  check(name === "1inch SwapVM v1.0" && version === "1.0.2", 'domain is ("1inch SwapVM v1.0", "1.0.2")');
}

type LiveShip = {
  txHash: string;
  blockNumber: bigint;
  maker: string;
  app: string;
  strategyHash: string;
  strategy: string;
};

/**
 * Collect the gen-2 Shipped events. Public RPCs cap eth_getLogs, so walk backwards in
 * chunks from head until we have covered the window the registry has been live.
 */
async function fetchLiveShips(): Promise<LiveShip[]> {
  heading("2. Live gen-2 ships");

  const head = await client.getBlockNumber();
  const CHUNK = 100_000n;
  // Fixed floor, not a rolling window: the reference-ship check below must keep passing for
  // anyone reproducing this later, and a head-minus-N window silently ages ship #0 out.
  const floor = GEN2_FIRST_ACTIVITY_BLOCK;

  const ships: LiveShip[] = [];
  let to = head;
  while (to > floor) {
    const from = to > floor + CHUNK ? to - CHUNK : floor;
    const logs = await client.getLogs({
      address: AQUA_REGISTRY,
      event: SHIPPED_EVENT,
      fromBlock: from,
      toBlock: to,
    });
    for (const log of logs) {
      // Decoding goes through the SDK's own parser, not our ABI, so the field mapping is theirs.
      const parsed = ShippedEvent.fromLog({ topics: [...log.topics], data: log.data });
      ships.push({
        txHash: log.transactionHash,
        blockNumber: log.blockNumber,
        maker: parsed.maker.toString(),
        app: parsed.app.toString(),
        strategyHash: parsed.strategyHash.toString(),
        strategy: parsed.strategy.toString(),
      });
    }
    if (from === floor) break;
    to = from - 1n;
  }

  ships.sort((a, b) => (a.blockNumber < b.blockNumber ? -1 : 1));
  info(`found ${ships.length} Shipped events on the gen-2 registry since its first activity block`);
  for (const ship of ships) {
    info(`  block ${ship.blockNumber} tx ${ship.txHash} maker ${ship.maker}`);
  }
  check(
    ships.some((s) => s.txHash.toLowerCase() === REFERENCE_SHIP_TX.toLowerCase()),
    `reference ship #0 (${REFERENCE_SHIP_TX.slice(0, 12)}...) is inside the scanned window`,
  );
  return ships;
}

function verifyRoundTrip(ships: LiveShip[]): void {
  heading("3. Builder round-trip vs live ships (does our SDK mirror the deployed opcode array?)");

  for (const ship of ships) {
    info(`ship ${ship.txHash.slice(0, 12)}... maker ${ship.maker}`);

    // PRG-R9: ship bytes are the ABI-encoded Order struct; strategyHash = keccak256(order bytes).
    const order = decodeShipBytes(ship.strategy);
    const hashMatches =
      keccak256(ship.strategy as `0x${string}`).toLowerCase() === ship.strategyHash.toLowerCase();
    check(hashMatches, "  strategyHash == keccak256(ship bytes) (PRG-R9 confirmed on live data)");

    const reEncoded = order.encode().toString();
    check(
      reEncoded.toLowerCase() === ship.strategy.toLowerCase(),
      "  Order.decode -> Order.encode reproduces the shipped bytes exactly",
    );

    let builder: ReturnType<typeof decodeProgram>;
    try {
      builder = decodeProgram(order.program.toString());
    } catch (error) {
      check(false, `  AquaProgramBuilder.decode threw: ${(error as Error).message}`);
      continue;
    }

    for (const line of renderInstructions(builder)) info(`    ${line}`);

    const rebuilt = builder.build().toString();
    check(
      rebuilt.toLowerCase() === order.program.toString().toLowerCase(),
      "  AquaProgramBuilder round-trip (decode -> build) is byte-identical",
    );

    info(`    traits: aqua=${order.traits.useAquaInsteadOfSignature} unwrap=${order.traits.shouldUnwrap} ` +
      `zeroIn=${order.traits.allowZeroAmountIn} preTransferOutHook=${order.traits.preTransferOutHook !== undefined}`);
  }
}

async function verifyMakersAreEoas(ships: LiveShip[]): Promise<void> {
  heading("4. Are the gen-2 makers EOAs? (supports the first pooled-custody Aqua maker claim)");

  const makers = [...new Set(ships.map((s) => s.maker.toLowerCase()))];
  for (const maker of makers) {
    const code = await client.getCode({ address: maker as `0x${string}` });
    const isEoa = code === undefined || code === "0x";
    info(`${maker}: ${isEoa ? "EOA (no code)" : `contract (${(code.length - 2) / 2} bytes of code)`}`);
  }
  const codes = await Promise.all(
    makers.map((m) => client.getCode({ address: m as `0x${string}` })),
  );
  const allEoa = codes.every((c) => c === undefined || c === "0x");
  check(allEoa, `all ${makers.length} gen-2 makers are EOAs (no pooled-custody maker exists yet)`);
}

function verifyFeeVariants(): void {
  heading("5. Fee-direction verdict: is a tokenOut protocol fee reachable in Aqua mode?");

  const table = aquaOpcodeTable();
  info("deployed-array mirror (@1inch/swap-vm-sdk@0.3.0 aquaInstructions, index = opcode byte):");
  for (const row of table) {
    if (row.name !== EMPTY_SLOT) info(`  ${row.hex} ${row.name}`);
  }
  const emptySlots = table.filter((r) => r.name === EMPTY_SLOT && r.index >= 0x0a);
  info(`  reserved/empty slots above the debug range: ${emptySlots.map((r) => r.hex).join(", ")}`);

  const names = AQUA_INSTRUCTION_SET.map((o) => o?.id.description ?? "");
  const outVariants = names.filter((n) => n.toLowerCase().includes("amountout"));
  check(
    outVariants.length === 0,
    "no *AmountOut* fee opcode exists in the Aqua instruction set (tokenOut fee NOT buildable)",
  );
  info(
    "  protocolFeeAmountOutXD / aquaProtocolFeeAmountOutXD / flatFeeAmountOutXD exist only in " +
      "_allInstructions (the regular SwapVM router set), not in aquaInstructions.",
  );
  info(
    "  Consequence: AquaProgramBuilder.add() rejects them, so under the no-hand-written-bytes rule " +
      "the on-chain protocol fee stays OUT of v1 (PRG-R7 v2 holds unchanged).",
  );
}

async function main(): Promise<void> {
  console.log("POO-1058 on-chain verification (read-only, Arbitrum mainnet)");
  console.log(`RPC head check against ${AQUA_REGISTRY} / ${AQUA_SWAP_VM_ROUTER}`);

  await verifyPairs();
  const ships = await fetchLiveShips();
  verifyRoundTrip(ships);
  await verifyMakersAreEoas(ships);
  verifyFeeVariants();

  heading("Result");
  if (failures === 0) {
    console.log("  ALL CHECKS PASSED");
  } else {
    console.log(`  ${failures} CHECK(S) FAILED`);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
