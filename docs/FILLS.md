# FILLS: settlement proofs

Every fill settled against an Active Reserve strategy on Arbitrum mainnet: three buy-side fills appended by `pnpm taker` as they ran, plus the two reverse fills from the close-out.


## What these fills are, and what they are not

**These are self-directed settlement proofs.** The fills below were executed by our own taker
wallet against our own strategy. They are not arbitrage profit and they are not organic
demand, and a below-spot bid band cannot win arbitrage by construction: it only becomes the
best bid when the market actually falls into it.

What they DO prove is that the machine settles: a real SwapVM program, shipped to the official
1inch Aqua registry, quoted through the official AquaSwapVMRouter, filled on Arbitrum mainnet, with the maker's capital withdrawn from Aave inside the settlement transaction when the fill
exceeds the hot buffer. That mechanism is the product.

In production the premium is paid by arbitrageurs when price enters the band, and by 1inch
routed flow once aggregation integrates Aqua. During this window the external, real yield is
the Aave carry, which accrues every block whether anyone fills or not.

| # | When (UTC) | Direction | Band (strategyHash) | Size in | Size out | Implied px | JIT | Tx |
|---|---|---|---|---|---|---|---|---|
| 1 | 2026-07-25 19:34:37 | BUY (taker sells WETH) | demo `0x77097fd3...` | 0.0003 WETH | 0.556382 USDC | $1854.61 | yes | [0xbc64ec2d...](https://arbiscan.io/tx/0xbc64ec2db39c6a8f718487268e4195c63e472f0ad0ae1f46e09919a1a9c5bb83) |
| 3 | 2026-07-25 19:43:19 | BUY | production `0xafbd59da...` | 0.00002 WETH | 0.035137 USDC | $1756.85 | yes | [0x22275ab5...](https://arbiscan.io/tx/0x22275ab56618064191e0bbcff058389722a3a1c9d54b14a89c5c0e10316a89f1) |
| 4 | 2026-07-25 ~21:30 | SELL, close-out | demo `0x77097fd3...` | 0.55 USDC | 0.000291745 WETH | $1885.19 | n/a | [0x11e946b3...](https://arbiscan.io/tx/0x11e946b3927e3c8e0bb6dca665faab1892dd9e2f2c121b4d70015f59b373fdfc) |
| 5 | 2026-07-25 ~21:32 | SELL, close-out | production `0xafbd59da...` | 0.035 USDC | 0.0000196 WETH | $1785.71 | n/a | [0x22932d2d...](https://arbiscan.io/tx/0x22932d2dc05af9531d284cb684433ff78605965b0b22785cd4295cb9b5127c8f) |

Rows 1 to 3 are the buy side: the taker sold WETH into the band and the vault paid USDC, every
one of them served by a just-in-time Aave withdrawal. Rows 4 and 5 are the close-out, run in
reverse (`scripts/unwind.ts`) so the vault could be redeemed in USDC: there the taker pays USDC
and the vault delivers WETH from inventory, which is why the JIT column does not apply. The
close-out rows were reconstructed from chain after the fact, which is why their timestamps are
approximate; the transaction hashes are exact.

## The JIT trace, decoded (fill #1)

Transaction [`0xbc64ec2d`](https://arbiscan.io/tx/0xbc64ec2db39c6a8f718487268e4195c63e472f0ad0ae1f46e09919a1a9c5bb83),
Arbitrum block 487666888, 336,000 gas. This is the mechanism the whole product rests on, and
it happens in **one transaction**:

| # | Contract | Event | Meaning |
|---|---|---|---|
| 1 | aUSDC | `Transfer` to 0x0 (BURN) 56,379 | Aave position burned: the carry sleeve is being withdrawn |
| 3 | USDC | `Transfer` aToken -> vault 56,382 | the withdrawn USDC arrives at the vault |
| 4 | Aave Pool | `Withdraw` | Aave's own record of the same withdrawal |
| 5 | PartyVault | `JitUnparked` | the vault's record: it covered a shortfall mid-settlement |
| 6 | USDC | `Transfer` vault -> taker 556,382 | the maker pays the taker |
| 7 | Aqua | `Pulled` | Aqua's accounting of that payment |
| 8 | WETH | `Transfer` taker -> router 3e14 | the taker's 0.0003 WETH goes in |
| 11 | WETH | `Transfer` router -> vault 3e14 | the ETH lands in the vault |
| 13 | Aqua | `Pushed` | Aqua credits the WETH side that shipped at amount 0 |
| 14 | AquaSwapVMRouter | `Swapped` | the swap itself |

**Read the numbers on rows 1 and 6 together.** The vault owed 556,382 USDC and its wallet held
500,000. It withdrew from Aave exactly 56,382, the shortfall and not a penny more, which is
VLT-R9 behaving as designed. Until the instant that transaction executed, every one of those
56,382 units was earning Aave interest.

That is the claim in one line: **capital earns yield until the exact second it buys the dip.**
Not a design intention, a decoded mainnet transaction.

