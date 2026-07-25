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

- **The live gen-2 router does NOT run `main` and does not match any public tag.** It runs the pre-`OpcodeList` array dispatch (v1.0.1-era): opcode = array index (`deadline`=0x0e, `xycSwap`=0x12, `concentrate`=0x13, `salt`=0x15, `flatFee`=0x16, `protocolFeeAmountInXD`=0x1c, `aquaProtocolFee`=0x1d, `extruction`=0x21). Under `main`'s banked enum those bytes are different or reserved. **Read `swap-vm` at tag `v1.0.1`, never `main`.** Line references in `00_ARCHITECTURE_AND_PLAN.md` were written against `main`; treat them as approximate and verify against `v1.0.1`.
- **Pin SDKs exactly, no caret**: `@1inch/swap-vm-sdk@0.3.0`, `@1inch/aqua-sdk@0.2.0`. Never hand-write opcode bytes; always go through `AquaProgramBuilder`.
- Ground-truth test (POO-1058): decode live ship #0 (tx `0xa966fc93f4519646528f082bce8640aa69146c9be9f77e4249ff446eba0fc166`) and assert our builder round-trips the same structure.

## Program-shape facts confirmed in source (do not re-litigate)

1. `safeBalances` never reads the ERC-20 wallet balance: a vault with a small hot buffer can quote the full sleeve; only `pull` at settlement needs real tokens. The 90/10 premise holds.
2. The `preTransferOut` maker hook fires BEFORE `AQUA.pull` in Aqua mode: JIT Aave withdrawal inside the settlement tx works.
3. **Fee direction trap**: `AquaProtocolFeeAmountIn`/`protocolFeeAmountInXD` charge on **tokenIn** and pull DURING `runLoop`, before settlement transfers. On a buy band tokenIn is WETH; a WETH-at-0 ship makes the fill revert. See PRG-R7 (v2) for the v1 resolution.
4. Ship bytes = the **ABI-encoded Order struct** (program inside the last slice of `order.data`), not the bare program. `strategyHash = keccak256(order bytes)`.
5. A docked strategyHash is dead forever (`_DOCKED`, not 0): every roll MUST change the salt.
6. Aqua mode enforces `receiver == maker` (the vault receives directly) and forbids WETH unwrap.
7. Chainlink ETH/USD on Arbitrum: `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` (8 decimals). Measured over 24h: 360 updates, median gap 121s, max 29.5 min. The 90-min staleness bound (D9) has zero false-trip margin risk.

## Fill in during POO-1058 / POO-1062

- [ ] Rehearsal tx hashes (fork): approve, ship, quote, swap, dock
- [ ] Builder round-trip vs live ship #0: PASS/FAIL
- [ ] `protocolFeeAmountOutXD` (fee charged on tokenOut = USDC) present in the deployed array and SDK? If yes, on-chain protocol fee returns in v1 charged in USDC
- [ ] Are the 4 gen-2 makers EOAs? (supports the "first pooled-custody Aqua maker" demo claim)
- [ ] Mainnet: adapter address, vault address, ship txs, strategyHashes (production band + demo band)

## Reproduction commands

```bash
export ETH_RPC_URL=https://arb1.arbitrum.io/rpc
cast call 0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de "AQUA()(address)"      # gen-2 pair
cast call 0x8fdd04dbf6111437b44bbca99c28882434e0958f "AQUA()(address)"      # gen-1 pair
cast call 0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de "eip712Domain()"       # "1inch SwapVM v1.0" / "1.0.2"
cast call 0x1111113db0e0ef9d0e3a50d5f094a3a57a26c0de "WETH()(address)"      # reverts: deployed build predates main/v1.0.1 WETH()
```

## Upstream call shapes, read from pinned source (Track A, POO-1059/POO-1060)

Upstream is public and fetchable without auth, so nothing below is guesswork and nothing is
vendored into this repo (Degensoft licenses):

```bash
curl -sL -o swapvm.tgz https://codeload.github.com/1inch/swap-vm/tar.gz/refs/tags/v1.0.1
curl -sL -o aqua.tgz   https://codeload.github.com/1inch/aqua/tar.gz/refs/tags/v1.0.0
```

| Call | Signature | Consequence |
|---|---|---|
| `Aqua.ship` | `ship(address app, bytes strategy, address[] tokens, uint256[] amounts) returns (bytes32)` | selector `0xf50b870f`, cross-checked against live ship tx `0xa966fc93...`. Returns `keccak256(strategy)`. Confirms PRG-R9 |
| `Aqua.dock` | `dock(address app, bytes32 strategyHash, address[] tokens)` | reverts `DockingShouldCloseAllTokens` unless `tokens` covers EVERY token the ship registered, so the vault stores the shipped list per hash |
| `Aqua.pull` | `pull(address maker, bytes32 hash, address token, uint256 amount, address to)` | executes `safeTransferFrom(maker, to, amount)`: the maker approves the **registry**, never the router |
| `Aqua.ship` immutability | requires `tokensCount == 0` per token; dock writes the `0xff` sentinel | a docked hash is dead forever. Hard-confirms PRG-R10: every roll MUST change the salt |
| maker hook | `IMakerHooks.preTransferOut(address maker, address taker, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, bytes32 orderHash, bytes makerData, bytes takerData)` | FIXED upstream interface, not a payload we choose. Called by the ROUTER on the maker in `SwapVM._transferOut` immediately before `AQUA.pull`, carrying the settled `amountOut`, so exact-amount JIT works. Supersedes the `onPreTransferOut(token, amount)` shape in the older frozen list |

## Aave v3 on Arbitrum (verified on chain 2026-07-25, POO-1060)

| What | Address | How it was verified |
|---|---|---|
| Aave v3 Pool | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` | matches the aToken's own `POOL()` getter |
| aArbUSDCn | `0x724dc807b04555b71ed48a6896b6F41593b8C637` | `UNDERLYING_ASSET_ADDRESS()` returns native USDC, `symbol()` is `aArbUSDCn`, 6 decimals |
| USDC (native) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | `symbol()` is `USDC` |
| WETH | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | used as the second registered token |

`AaveV3Adapter` re-runs the aToken checks in its constructor, so a mis-wired pair cannot deploy.

Measured on an Arbitrum fork of live state (POO-1060 suite):

- JIT overhead per fill: **26,128 gas** (92,494 with the Aave withdraw inside the fill versus 66,366
  when the hot buffer covers it). Cents at Arbitrum gas prices, far below the 80 bps premium on any
  fill worth doing.
- aUSDC carry over 90 warped days on 100k USDC: **263 bps implied APR**.
