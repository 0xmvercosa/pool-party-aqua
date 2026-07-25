/**
 * Reconstruct a live Aqua strategy from chain data alone.
 *
 * The taker deliberately does NOT read our database or our compiler output. Everything it
 * needs is in the `Shipped` event: `strategy` carries the full ABI-encoded Order, so anyone
 * with an RPC can rebuild the order, quote it, and fill it. That is the property that makes
 * this public repo self-contained, and it is also the honest way to demonstrate that the
 * strategy is real rather than a private arrangement between our own scripts.
 */
import { Order } from "@1inch/swap-vm-sdk";
import type { PublicClient } from "viem";
import { AQUA_REGISTRY } from "./addresses.ts";
import { TOPICS, parseShipped } from "./events.ts";
import { decodeProgram, renderInstructions } from "./program.ts";

export type ReconstructedStrategy = {
  strategyHash: `0x${string}`;
  maker: string;
  app: string;
  order: Order;
  program: string;
  instructions: string[];
  shipTxHash: `0x${string}`;
  shipBlock: bigint;
};

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

/**
 * Walk back from head in chunks until the ship is found. Public RPCs cap `eth_getLogs`, so a
 * single wide query is not portable; chunking keeps this runnable against arb1.arbitrum.io.
 */
export async function reconstructFromChain(
  client: PublicClient,
  strategyHash: `0x${string}`,
  options: { searchBlocks?: bigint; chunk?: bigint } = {},
): Promise<ReconstructedStrategy> {
  const head = await client.getBlockNumber();
  const searchBlocks = options.searchBlocks ?? 3_000_000n;
  const chunk = options.chunk ?? 100_000n;
  const floor = head > searchBlocks ? head - searchBlocks : 0n;

  let to = head;
  while (to > floor) {
    const from = to > floor + chunk ? to - chunk : floor;
    const logs = await client.getLogs({
      address: AQUA_REGISTRY,
      event: SHIPPED_EVENT,
      fromBlock: from,
      toBlock: to,
    });

    for (const log of logs) {
      if (log.topics[0] !== TOPICS.shipped && log.topics.length > 0) continue;
      const shipped = parseShipped(log);
      if (shipped.strategyHash.toString().toLowerCase() !== strategyHash.toLowerCase()) continue;

      const strategy = shipped.strategy.toString();
      const order = Order.decode(shipped.strategy);
      const program = order.program.toString();
      return {
        strategyHash,
        maker: shipped.maker.toString(),
        app: shipped.app.toString(),
        order,
        program,
        instructions: renderInstructions(decodeProgram(program)),
        shipTxHash: log.transactionHash,
        shipBlock: log.blockNumber,
      };
    }

    if (from === floor) break;
    to = from - 1n;
  }

  throw new Error(
    `No Shipped event for ${strategyHash} in the last ${searchBlocks} blocks on ${AQUA_REGISTRY}. ` +
      "Widen the search with --search-blocks, or check the strategyHash.",
  );
}
