# VERIFIED: canonical addresses and ground truth (Arbitrum)

**Status:** pre-seeded from Rafael's source + on-chain review (2026-07-25). POO-1058's fork rehearsal must RE-CONFIRM the marked items before any mainnet approve.

## The two Aqua generations on Arbitrum

There is no address "discrepancy": two complete, parallel generations are deployed. The upstream READMEs document the dead one; `@1inch/swap-vm-sdk@0.3.0` references only generation 2.

| | Aqua registry | AquaSwapVMRouter | EIP-712 domain | Activity |
|---|---|---|---|---|
| Gen 1 (DEAD, do not use) | `0x499943e74fb0ce105688beee8ef2abec5d936d31` | `0x8fdd04dbf6111437b44bbca99c28882434e0958f` | ("AquaSwapVMRouter", "1.0.0") | 43 ships, 579 pulls, last ~2026-04 |
| **Gen 2 (LIVE, use this)** | `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a` | `0x1111113Db0e0ef9D0E3A50d5f094a3a57a26C0DE` | ("1inch SwapVM v1.0", "1.0.2") | 4 ships (2026-07-20/21), 14 pulls, last 2026-07-24 |

Each router's `AQUA()` getter points at its own registry (pairs are fixed).

## Source-of-truth pinning (critical)

- **The live gen-2 router does NOT run `main` and does not match any public tag.** It runs the pre-`OpcodeList` array dispatch (v1.0.1-era): opcode = array index. Under `main`'s banked enum those bytes are different or reserved. **Read `swap-vm` at tag `v1.0.1`, never `main`.** Line references in `00_ARCHITECTURE_AND_PLAN.md` were written against `main`; treat them as approximate and verify against `v1.0.1`.
- **Pin SDKs exactly, no caret**: `@1inch/swap-vm-sdk@0.3.0`, `@1inch/aqua-sdk@0.2.0`. Never hand-write opcode bytes; always go through `AquaProgramBuilder`.
- Ground-truth test (POO-1058): decode live ship #0 (tx `0xa966fc93f4519646528f082bce8640aa69146c9be9f77e4249ff446eba0fc166`) and assert our builder round-trips the same structure. **DONE, PASS** (see below).

### Opcode table: MEASURED, supersedes the earlier estimate (POO-1058, 2026-07-25)

The pre-seeded table in this file was **off by one across the board**. Measured truth: `@1inch/swap-vm-sdk@0.3.0`'s `instructions.aquaInstructions` array mirrors the deployed array **exactly**. Proof: all four live gen-2 ships decode through `AquaProgramBuilder.decode()` and re-`build()` to byte-identical program bytes. A one-off table would have produced garbage args or thrown on the first instruction.

| Opcode | Instruction | | Opcode | Instruction |
|---|---|---|---|---|
| 0x00-0x09 | reserved (debug slots) | | 0x14 | `Controls.salt` |
| 0x0a | `Controls.jump` | | 0x15 | `Fee.flatFeeAmountInXD` |
| 0x0b | `Controls.jumpIfTokenIn` | | 0x16-0x1a | **EMPTY / not implemented** |
| 0x0c | `Controls.jumpIfTokenOut` | | 0x1b | `Fee.protocolFeeAmountInXD` |
| 0x0d | `Controls.deadline` | | 0x1c | `Fee.aquaProtocolFeeAmountInXD` |
| 0x0e | `Controls.onlyTakerTokenBalanceNonZero` | | 0x1d | `Fee.dynamicProtocolFeeAmountInXD` |
| 0x0f | `Controls.onlyTakerTokenBalanceGte` | | 0x1e | `Fee.aquaDynamicProtocolFeeAmountInXD` |
| 0x10 | `Controls.onlyTakerTokenSupplyShareGte` | | 0x1f | `PeggedSwap.peggedSwapGrowPriceRange2D` |
| 0x11 | `XYCSwap.xycSwapXD` | | 0x20 | `Extruction.extruction` |
| 0x12 | `XYCConcentrate.concentrateGrowLiquidity2D` | | 0x21 | `Controls.onlyTxOriginTokenBalanceNonZero` |
| 0x13 | `Decay.decayXD` | | | |

Reproduce: `pnpm verify:onchain`.

## Program-shape facts confirmed in source (do not re-litigate)

1. `safeBalances` never reads the ERC-20 wallet balance: a vault with a small hot buffer can quote the full sleeve; only `pull` at settlement needs real tokens. The 90/10 premise holds.
2. The `preTransferOut` maker hook fires BEFORE `AQUA.pull` in Aqua mode: JIT Aave withdrawal inside the settlement tx works.
3. **Fee direction trap**: `AquaProtocolFeeAmountIn`/`protocolFeeAmountInXD` charge on **tokenIn** and pull DURING `runLoop`, before settlement transfers. On a buy band tokenIn is WETH; a WETH-at-0 ship makes the fill revert. See PRG-R7 (v2) for the v1 resolution. **CORRECTION (POO-1058):** PRG-R7 v2 justified this partly with "confirmed [...] by all 4 live programs avoiding it". That is false. **All four live gen-2 programs USE `aquaProtocolFeeAmountInXD`** (0x1c, fee 125000 or 25000 of 1e9, to `0x8063d4faf54bf8c898dc6ddc689c76ab12b4614a`). They can afford to: they ship both sides with non-zero amounts, so the tokenIn pull always has balance. Our WETH-at-0 buy band is the case that breaks. The rule's conclusion stands; only its evidence was wrong.
4. Ship bytes = the **ABI-encoded Order struct** (program inside the last slice of `order.data`), not the bare program. `strategyHash = keccak256(order bytes)`.
5. A docked strategyHash is dead forever (`_DOCKED`, not 0): every roll MUST change the salt.
6. Aqua mode enforces `receiver == maker` (the vault receives directly) and forbids WETH unwrap.
7. Chainlink ETH/USD on Arbitrum: `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` (8 decimals). Measured over 24h: 360 updates, median gap 121s, max 29.5 min. The 90-min staleness bound (D9) has zero false-trip margin risk.

## Live gen-2 program shape (measured, POO-1058)

All four ships, decoded. This is what a program that actually works on the deployed router looks like:

| Ship | Maker | Program |
|---|---|---|
| `0xa966fc93` (#0) | `0x410326e6...` EOA | `[onlyTxOriginTokenBalanceNonZero][aquaProtocolFeeAmountInXD 1.25bps][concentrateGrowLiquidity2D][flatFeeAmountInXD 5bps][xycSwapXD][salt]` |
| `0xafa9db26` | `0x6edc317f...` EOA | same shape |
| `0x275ec8e6` | `0x6edc317f...` EOA | same shape |
| `0xfc718c94` | `0x6edc317f...` EOA | `[onlyTxOrigin...][aquaProtocolFeeAmountInXD 0.25bps][flatFeeAmountInXD 1bps][peggedSwapGrowPriceRange2D][salt]` |

Three facts this settles, all of which contradict the pre-seeded PRG-R1 v2 order:

1. **`concentrateGrowLiquidity2D` is NOT the terminal curve.** It shapes reserves; `xycSwapXD` (0x11) is the instruction that executes the constant-product swap on the shaped reserves. A concentrate program with no `xycSwapXD` has no executing curve. (The pegged variant IS self-contained, which is why ship #4 has no `xycSwapXD`.) The SDK's own `AquaXYCAmmStrategy.build()` emits the same pair in the same order.
2. **The flat fee goes AFTER concentrate, immediately before `xycSwapXD`**, not before concentrate.
3. **`salt` sits AFTER the terminal curve** in every live program. That is consistent with "curves are terminal": `salt` is a documented no-op whose only effect is on the order hash, so post-curve placement costs nothing.

Corrected canonical order for our band strategy (PRG-R1 v3 proposal, pending Murilo's ack since program order is a frozen interface):

```
[deadline][concentrateGrowLiquidity2D][flatFeeAmountInXD 80bps][xycSwapXD][salt]
```

`deadline` (0x0d) is used by no live program; it is our own epoch guard and belongs first, before anything executes.

## Fill in during POO-1058 / POO-1062

- [x] **Builder round-trip vs live ship #0: PASS** (byte-identical on all 4 live ships, `pnpm verify:onchain`)
- [x] **`protocolFeeAmountOutXD` present in the deployed array and SDK? NO.** The Aqua instruction set has no `*AmountOut*` fee opcode at all: slots 0x16-0x1a are empty, and `protocolFeeAmountOutXD` / `aquaProtocolFeeAmountOutXD` / `flatFeeAmountOutXD` exist only in `_allInstructions` (the regular SwapVM router set), never in `aquaInstructions`. `AquaProgramBuilder.add()` rejects them by construction. **Verdict: the on-chain protocol fee stays OUT of v1. PRG-R7 v2 holds unchanged.**
- [x] **Are the gen-2 makers EOAs? YES.** Four ships, two distinct makers (`0x410326e6...`, `0x6edc317f...`), both with zero code. No pooled-custody Aqua maker exists yet; the demo claim holds.
- [ ] Rehearsal tx hashes (fork): approve, ship, quote, swap, dock
- [ ] Hook firing (`preTransferOut`) with a stub maker on the fork
- [ ] Mainnet: adapter address, vault address, ship txs, strategyHashes (production band + demo band)

## Reproduction commands

```bash
pnpm verify:onchain   # every claim above marked [x], from a clean checkout, no tx sent

export ETH_RPC_URL=https://arb1.arbitrum.io/rpc
cast call 0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de "AQUA()(address)"      # gen-2 pair
cast call 0x8fdd04dbf6111437b44bbca99c28882434e0958f "AQUA()(address)"      # gen-1 pair
cast call 0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de "eip712Domain()"       # "1inch SwapVM v1.0" / "1.0.2"
cast call 0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de "WETH()(address)"      # reverts: deployed build predates main/v1.0.1 WETH()
```
