/**
 * POO-1062 step 3: build the two launch Order payloads for the LIVE vault.
 *
 * Reads the Chainlink spot at build time and emits, for each band, the ABI-encoded Order
 * bytes ShipBand expects in ORDER_BYTES, plus the strategyHash and the agreed SHIP_USDC.
 * Program per PRG-R1 v3; maker = the deployed PartyVault; the preTransferOut hook rides a
 * zero-address Interaction with non-empty data (the measured SDK requirement).
 *
 * Usage: VAULT_ADDRESS=0x... pnpm tsx scripts/build-orders.ts
 */
import { Interaction } from "@1inch/sdk-core";
import { Address, AquaProgramBuilder, HexString, MakerTraits, Order } from "@1inch/swap-vm-sdk";
import { http, createPublicClient } from "viem";
import { arbitrum } from "viem/chains";
import { CHAINLINK_ETH_USD } from "./lib/addresses.ts";
import { type Band, bandFromSpot, concentrateArgsFor, describeBand } from "./lib/band.ts";
import { arbitrumRpcUrl } from "./lib/env.ts";
import { heading, info } from "./lib/format.ts";
import { renderInstructions } from "./lib/program.ts";

const EPOCH_SECONDS = 3n * 86_400n; // D5: 3-day epoch

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

function buildBandOrder(vault: string, band: Band, saltValue: bigint, nowTs: bigint) {
  // PRG-R1 v3 (measured): [deadline][concentrate][flatFee 80bps][xycSwapXD][salt]
  // Exactly the calls the fork-green rehearsal used (rehearse-taker.ts): no novelty at launch.
  const builder = new AquaProgramBuilder()
    .deadline({ deadline: nowTs + EPOCH_SECONDS })
    .concentrateGrowLiquidity2D(concentrateArgsFor(band))
    .flatFeeAmountInXD({ fee: 8_000_000n }) // 80 bps at 1e9 = 100%
    .xycSwapXD()
    .salt({ salt: saltValue });
  const program = builder.build();
  const traits = MakerTraits.default().with({
    preTransferOutHook: new Interaction(Address.ZERO_ADDRESS, new HexString("0x01")),
  });
  const order = Order.new({ maker: new Address(vault), traits, program });
  return { order, builder };
}

async function main(): Promise<void> {
  const vault = process.env.VAULT_ADDRESS;
  if (!vault) throw new Error("Set VAULT_ADDRESS (from the deploy) first");

  const client = createPublicClient({ chain: arbitrum, transport: http(arbitrumRpcUrl()) });
  const [, answer] = await client.readContract({
    address: CHAINLINK_ETH_USD,
    abi: CHAINLINK_ABI,
    functionName: "latestRoundData",
  });
  const block = await client.getBlock();
  const spotE8 = BigInt(answer);
  info(`Chainlink ETH/USD spot: $${(Number(spotE8) / 1e8).toFixed(2)} (block ${block.number})`);

  // Salts derive from the block number so every roll is guaranteed a fresh value (PRG-R10).
  const epochBase = block.number;

  const bands: Array<{ name: string; band: Band; salt: bigint; shipUsdc: string }> = [
    { name: "DEMO band (-0.3% .. -0.1%)", band: bandFromSpot(spotE8, -30n, -10n), salt: epochBase * 10n + 1n, shipUsdc: "600000" },
    { name: "PRODUCTION band (-15% .. -5%)", band: bandFromSpot(spotE8, -1500n, -500n), salt: epochBase * 10n + 2n, shipUsdc: "400000" },
  ];

  for (const { name, band, salt, shipUsdc } of bands) {
    const { order, builder } = buildBandOrder(vault, band, salt, block.timestamp);
    heading(name);
    info(describeBand(band));
    for (const line of renderInstructions(builder)) info(`  ${line}`);
    info(`strategyHash: ${order.hash()}`);
    info(`SHIP_USDC=${shipUsdc}`);
    info(`ORDER_BYTES=${order.encode()}`);
  }

  info("");
  info("Next: export ORDER_BYTES + SHIP_USDC for ONE band and run Ops.s.sol:ShipBand; repeat for the other.");
}

main().catch((error) => {
  console.error(`\n${(error as Error).message}`);
  process.exitCode = 1;
});
