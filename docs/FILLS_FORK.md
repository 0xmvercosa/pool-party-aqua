# FILLS (FORK REHEARSAL, not real): settlement proofs

Every fill executed against an Active Reserve strategy, appended by `pnpm taker` as it runs.

**Nothing in this file happened on mainnet.** These rows come from `pnpm rehearse:taker`
against a local Anvil fork and exist to show the path works before real money moves. The
real settlements live in `FILLS.md`.


## What these fills are, and what they are not

**These are self-directed settlement proofs.** The fills below were executed by our own taker
wallet against our own strategy. They are not arbitrage profit and they are not organic
demand, and a below-spot bid band cannot win arbitrage by construction: it only becomes the
best bid when the market actually falls into it.

What they DO prove is that the machine settles: a real SwapVM program, shipped to the official
1inch Aqua registry, quoted through the official AquaSwapVMRouter, filled on Arbitrum mainnet,
with the maker's capital withdrawn from Aave inside the settlement transaction when the fill
exceeds the hot buffer. That mechanism is the product.

In production the premium is paid by arbitrageurs when price enters the band, and by 1inch
routed flow once aggregation integrates Aqua. During this window the external, real yield is
the Aave carry, which accrues every block whether anyone fills or not.

| # | When (UTC) | Band | Size in | Size out | Implied px | JIT | Tx |
|---|---|---|---|---|---|---|---|

<!-- strategy: demo 0xf951f611efd46c08df1a5f619e5ee1b8c28d9c57f8d95a18c59bec709228a4e6 on fork -->
| 1 | 2026-07-25 16:43:40 | demo | 0.01 WETH | 18.497409 USDC | $1849.74 | no | 0xfadcecb1... (fork) |
| 2 | 2026-07-25 16:43:58 | demo | 0.5 WETH | 924.433668 USDC | $1848.87 | yes | 0x6cac72af... (fork) |
