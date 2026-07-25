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

<!-- strategy: demo 0x98c6a2483ada1fa9f9c9baa26613d9ac003563faf44330ad2cb99bd0ff1fa280 on fork -->
| 1 | 2026-07-25 16:54:48 | demo | 0.01 WETH | 18.488194 USDC | $1848.82 | no | 0x9855961b... (fork) |
| 2 | 2026-07-25 16:54:50 | demo | 0.5 WETH | 923.973349 USDC | $1847.95 | yes | 0xbc8058a0... (fork) |
