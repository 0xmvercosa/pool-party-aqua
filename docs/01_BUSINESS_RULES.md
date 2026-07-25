# Aqua Strategies: Business Rules (v1)

**Date:** 2026-07-25
**Status:** v2 (post Rafael source/on-chain review, 2026-07-25; amendments approved by Murilo). ALL decisions D1-D10 RESOLVED. Upstream source of truth PINNED: the live gen-2 router runs the v1.0.1-era array opcode table, read `swap-vm@v1.0.1`, NEVER `main`; SDKs pinned exact (`@1inch/swap-vm-sdk@0.3.0`, `@1inch/aqua-sdk@0.2.0`). Canonical addresses and confirmed traps: `docs/VERIFIED.md`. History on the epic [POO-1057](https://linear.app/yeildbay/issue/POO-1057).
**Scope:** single source of truth for all numbered rules of the Aqua hackathon build. Each Linear issue embeds its own subset verbatim; on divergence, THIS FILE wins and the issue must be re-synced. Canonical home: `docs/` of this dedicated hackathon repo.

Component prefixes: VLT (PartyVault), ADP (carry adapter), SRV (server module + database), PRG (program compiler), KPR (keepers), BOT (taker bot), IDX (indexer/NAV), RTR (PartyRouter), FE (frontend). Cross-references use `VLT-R4` style.

> **Addendum (Murilo, 2026-07-25):** there is NO separate backend service. All orchestration runs as a server-only module inside this Next app (server actions + scripts), which implies Next persists state in a database. See SRV rules.

---

## VLT: PartyVault ([POO-1059](https://linear.app/yeildbay/issue/POO-1059))

> **20h-window cut (approved):** in-window scope = R1 (4626 math + decimals offset), R2 (manager seeds first), R3 (internal ledger + views + events), execShip/execDock under a SINGLE OWNER, R9 (JIT hook, allowlisted router only), R10 reduced to `maxTvl` only, R11 (dockAll). DEFERRED and named in the README as designed-but-not-shipped: R4 (in-vault staleness gate; status script reads the feed off-chain), R6 (lockup), R7 keeper role split (no keeper exists in-window), R8 (HWM performance fee), maxPerShip + token allowlist (no external capital in-window; window seed is $50-200 per amended D3).

- **VLT-R1** Deposits are USDC only. Shares minted with OpenZeppelin ERC-4626 math internally (same conversion formulas, rounding down, decimals offset +3 anti-inflation). Deposit reverts if resulting TVL > `maxTvl`.
- **VLT-R2** The first deposit must come from the MANAGER address (manager seed); other deposits revert until seeded.
- **VLT-R3** No ERC-20 share token: internal `mapping(address => shares)`, no Transfer events, transfers impossible by construction. Public views `sharesOf`, `convertToShares`, `convertToAssets`, `totalAssets`; events `Deposited(investor, assets, shares)`, `Redeemed(investor, assets, shares)`.
- **VLT-R4** `totalAssets` = wallet USDC + `adapter.parkedBalance(USDC)` + wallet WETH valued at Chainlink ETH/USD. Feed stale beyond `maxStaleness` (D9 RESOLVED: 90 min) makes deposit and redeem revert. No NAV without a fresh price.
- **VLT-R5** Redemption burns shares, pays USDC only. Insufficient liquid USDC (buffer + parked) reverts with `InsufficientLiquidUsdc`. No in-kind payout in v1.
- **VLT-R6** Lockup `lockupDays` per vault param (D4 RESOLVED: 0 days for the hackathon); early redeem reverts.
- **VLT-R7** Roles: MANAGER and KEEPER may call `execShip` / `execDock` / `dockAll` only, restricted to allowlisted routers and tokens, per-token ship amount <= `maxPerShip`. No role has a path that transfers funds to an arbitrary address. No upgradability. No pause-and-take.
- **VLT-R8** Performance fee `perfFeeBps` (D4 RESOLVED: 20%) on share-price high-water mark, accrued as newly minted shares to MANAGER on deposit / redeem / `accrueFee()`. Global HWM is sound because shares are non-transferable. Protocol fee lives in the program (PRG-R7), not the vault.
- **VLT-R9 (v2, measured signature)** The JIT hook is `preTransferOut(maker, taker, tokenIn, tokenOut, amountIn, amountOut, orderHash, makerHookData, takerHookData)` (selector `0x5a394f80`, measured in POO-1058), callable only by the allowlisted router during settlement; it unparks the shortfall of `tokenOut` beyond the hot buffer. SDK detail: the hook target rides a zero-address Interaction and the hook data must be non-empty. Sweep back to adapter is keeper-driven (KPR-R5).
- **VLT-R10** Caps (`maxTvl`, `maxPerShip`, allowlists, buffer target) adjustable by MANAGER only.
- **VLT-R11** `dockAll()` docks every active strategy; MANAGER or KEEPER; accounting-only emergency stop.

## ADP: Carry adapter ([POO-1060](https://linear.app/yeildbay/issue/POO-1060))

- **ADP-R1** `park` / `unpark` callable only by the owning vault.
- **ADP-R2** `unpark(token, amount)` withdraws exactly `amount` from Aave v3; bubbles Aave's revert on utilization stress. The vault treats that revert as temporarily illiquid, never bad debt.
- **ADP-R3** `parkedBalance` returns interest-inclusive aToken balance (continuous accrual in `totalAssets`).
- **ADP-R4** Adapter holds aTokens only; never more than transient underlying during park/unpark.
- **ADP-R5** No admin or rescue functions in v1; replacement = new vault deployment.
- Frozen interface: `park(address,uint256)`, `unpark(address,uint256)`, `parkedBalance(address) returns (uint256)`.

## SRV: Server module + database ([POO-1071](https://linear.app/yeildbay/issue/POO-1071)) - **v3** (Murilo 2026-07-25: internal API module; DB is a Neon prod mirror; module lives in the pool-party-frontend hackathon branch)

- **SRV-R1 (v3)** Strict layering, three tiers, all inside the pool-party-frontend Next app on the dedicated hackathon branch (`feat/aqua-poo-1057-hackathon`, never merged during the event): (1) thin **server actions** (input validation + session/auth only, zero business logic); (2) the **Aqua API module** (`src/lib/aqua/api/`, server-only), which plays the role of pool-party-api for this app: saves strategies/mandates to the database, orchestrates on-chain calls (sends keeper/bot txs with server-side keys; returns BuiltTx payloads for anything a wallet must sign), and hosts the domain services (compiler, indexer/NAV, keeper logic, bot logic); (3) infra clients (Drizzle, viem). The API module is the ONLY layer allowed to touch Drizzle or viem. No separate backend service exists.
- **SRV-R2 (v3)** The database is the **Neon mirror of prod created by Murilo (2026-07-25)**: it already carries the real pool-party-api data model and data. The aqua module introspects that schema and EXTENDS it with `aqua_ships` (strategyHash, program bytes, epoch, status), `aqua_fills`, `aqua_nav_snapshots`, `aqua_keeper_log` via Drizzle migrations; money columns as numeric strings (never JS float). SECURITY: the connection string lives ONLY in local `.env` files (gitignored), never in code, docs, Linear, or commits; no data from the mirror may ever be committed anywhere (the pool-party-aqua repo goes public at submission); rotate the credential after the hackathon.
- **SRV-R3** Long-running processes (keeper loop, taker bot) execute the SAME server module via repo scripts (`pnpm aqua:keeper`, `pnpm aqua:taker`, tsx), not inside request handlers. A route handler + external cron is an accepted later alternative; Vercel cron is NOT assumed (real mode deploys to AWS dev).
- **SRV-R4** Keeper key, bot key, and RPC URLs are server env only; never `NEXT_PUBLIC_*`; never imported client-side.
- **SRV-R5** Anything a wallet signs (manager or investor) is returned by a server action as a `builtTxSchema`-validated payload consumed by `useWalletSignFlow`, matching the existing trust boundary.
- **SRV-R6** Solidity contracts (PartyVault, adapter, PartyRouter) live in the dedicated `pool-party-aqua` repo under `contracts/` (Foundry), together with deploy/rehearsal scripts and the canonical docs; the Next module and UI live in the pool-party-frontend hackathon branch (two homes, epic Structure update).

## PRG: Program compiler ([POO-1061](https://linear.app/yeildbay/issue/POO-1061))

- **PRG-R1 (v3, MEASURED; acked by Murilo 2026-07-25 when authorizing the merge train, recorded on POO-1057)** Canonical v1 program order, always: `[deadline][concentrateGrowLiquidity2D][flatFeeAmountInXD 80bps][xycSwapXD][salt]`. Measured against all four live gen-2 programs and proven in trap C: `concentrateGrowLiquidity2D` is a reserve SHAPER, not a terminal curve; `xycSwapXD` executes the swap on the shaped reserves, and a program without it has no executing curve. The v2 order runs the fee after the executing curve and REVERTS on-chain (`TakerTraitsAmountOutMustBeGreaterThanZero`); a fee emitted after `xycSwapXD` makes the strategy unquotable, it is NOT silently ignored. The on-chain protocol fee opcode stays OUT of v1 (PRG-R7 v3); the tokenOut fee variant is measured ABSENT from the Aqua set (trap F), closing the old rehearsal check.
- **PRG-R2 (v2)** Ship registers BOTH tokens (registration = `tokensCount`, required by `safeBalances`/`push`). Amount 0 on the empty side is valid ONLY if no opcode pulls that token during execution. Because `*FeeAmountIn` opcodes pull **tokenIn** (WETH on our buy band) inside `runLoop`, the v1 program must contain NO tokenIn-pulling fee opcode (see PRG-R7 v2). Compiler enforces: for every opcode in the program that pulls token T, shipped amount of T must cover it.
- **PRG-R3** Band entirely below spot at build time: `bandHigh <= chainlinkSpot * 0.98`; compiler refuses otherwise.
- **PRG-R4** `deadline` = epoch end (D5 RESOLVED: **3 days**, Murilo picked the short epoch for more live rolls); `salt` = epoch id (docked strategyHash is dead forever).
- **PRG-R5** Shipped USDC <= min(`maxPerShip`, `bandSleevePct` x totalAssets) (D5 RESOLVED: 10%).
- **PRG-R6** Coverage v1 = 1.0: sum of shipped USDC across active strategies <= vault total USDC. No over-commit in v1 (SLAC deferred to later products).
- **PRG-R7 (v3)** v1 program carries the 80 bps flat fee ONLY (`flatFee`, a pure price adjustment, no transfer, accrues to the maker). The on-chain protocol fee via `aquaProtocolFeeAmountInXD` is OUT of v1: it charges on tokenIn (WETH) during `runLoop` and reverts against our WETH-at-0 buy band (proven on the fork, trap E). Evidence correction from the measurement: all four live gen-2 programs USE that opcode; they can afford to because they ship both sides non-zero, which is exactly the case our buy band is not. The tokenOut variant does not exist in the Aqua instruction set (trap F), so there is no in-USDC alternative on the deployed router. Platform economics for the window: documented, not charged (HWM fee deferred with VLT-R8). Only allowlisted routers as `app`.
- **PRG-R8** Roll = `dock(old) + ship(new)` batched in one action.
- **PRG-R9 (new)** The bytes shipped to Aqua are the **ABI-encoded Order struct** (program inside the last slice of `order.data`; hook-slice offsets in traits bits 160-223), not the bare program. `strategyHash = keccak256(order bytes)`. `compile()`'s return shape reflects this.
- **PRG-R10 (new)** A docked strategyHash is dead forever. Every roll MUST change the salt; the compiler enforces it and has a test for it. Aqua mode also requires `receiver == maker` (the vault) and forbids WETH unwrap.
- Frozen mandate shape: `{ pair: {base: WETH, quote: USDC}, bandLowPct, bandHighPct, feeBps, epochDays, bandSleevePct, maxPerShip }`.

## KPR: Keepers ([POO-1069](https://linear.app/yeildbay/issue/POO-1069))

- **KPR-R1** Roll at epoch end per mandate policy (auto or queue for manager signature).
- **KPR-R2** Drift re-ship at TVL drift > 10% (D5), debounced (min 1h).
- **KPR-R3** Coverage sentinel: liquid coverage < 1.0 triggers smaller re-ship within one cycle.
- **KPR-R4** Price sentinel: dock on Chainlink staleness > 90 min (D9) or spot through band floor beyond mandate bounds. Sole price protection until RTR lands; critical.
- **KPR-R5** Re-park sweep each cycle; hot buffer target 5% of USDC sleeve (D5).
- **KPR-R6** Every action logs decision inputs + tx hash.
- **KPR-R7** Unexpected revert stops the loop and alerts; never retry-storm mainnet.

## BOT: Taker bot ([POO-1066](https://linear.app/yeildbay/issue/POO-1066))

- **BOT-R1** MVP: configurable size, dry-run mode, single fill on command.
- **BOT-R2 (v2)** In-window fills are **self-directed settlement proofs** from our own taker wallet, labeled as such everywhere (a below-spot bid band cannot win arbitrage by construction). In production, organic fills are CONDITIONAL on the market entering the band: during real dips, selling to the band becomes the best bid and arbitrageurs fill it; that is the product working as designed. Arb mode (profit > gas + margin) only ever fires in that regime and stays CUT for the window.
- **BOT-R3** Max size per fill + max daily volume caps; never exceeds quoted depth.
- **BOT-R4** Bot wallet separate from manager/keeper keys; holds only working capital.
- **BOT-R5** Every fill's tx hash appended to `FILLS.md`.

## IDX: Indexer / NAV ([POO-1065](https://linear.app/yeildbay/issue/POO-1065))

- **IDX-R1** Consume Aqua `Shipped/Docked/Pushed/Pulled`, router `Swapped`, vault `Deposited/Redeemed`; persist per strategyHash and vault.
- **IDX-R2** Live money display always from fresh reads (`rawBalances`, `parkedBalance`, wallet balances), never cache.
- **IDX-R3** Share price mirrors VLT-R4 exactly; divergence from on-chain `convertToAssets` beyond rounding is a bug.
- **IDX-R4** Attribution: carry = aToken growth; fill P&L = push value - pull value at fill-time Chainlink; premium = flat-fee share. Daily + per-epoch rollups.
- **IDX-R5** Outputs: JSON feed for the FE `aqua` block + human-readable report.
- **IDX-R6** Transaction-display rule applies: per-token amount + USD at tx time.

## RTR: PartyRouter ([POO-1063](https://linear.app/yeildbay/issue/POO-1063))

- **RTR-R1** Only changes vs official SwapVM source: one `OpcodeList.sol` slot claim, one dispatch line, one router contract. Diff fits on one screen.
- **RTR-R2** We write the missing tests: quote/swap parity with the adjuster, staleness revert, `maxPriceDecay` clamp both directions, fuzz.
- **RTR-R3** Params per D9 (RESOLVED: maxPriceDecay 50 bps, maxStaleness 90 min). Feed address is a program argument.
- **RTR-R4** Source published (Degensoft copyleft + hackathon requirement); Arbiscan-verified.
- **RTR-R5** Migration: allowlist PartyRouter in the vault, roll live strategy onto an oracle-guarded program; official router stays allowlisted as fallback during the hackathon.
- **RTR-R6** Compiler emits the oracle instruction only when targeting PartyRouter.
- **RTR-R7** Demo evidence: one rejected under-priced fill captured.

## FE: Frontend, product copy

- **FE-R10** Official product name: **Active Reserve** (D8 RESOLVED). Official description (<=280 chars, EN, use verbatim in catalog/detail/submission): "An always-earning reserve that buys the dip. Capital earns Aave lending yield every block and is deployed automatically the instant the market dips into the manager's buy band, purchasing ETH below market price. Objective: accumulate ETH at a discount while never sitting idle."

## FE: Frontend ([POO-1064](https://linear.app/yeildbay/issue/POO-1064), [POO-1067](https://linear.app/yeildbay/issue/POO-1067), [POO-1068](https://linear.app/yeildbay/issue/POO-1068))

- **FE-R1** `protocol: "uniswap-v3" | "aqua"` optional discriminator; absent = uniswap-v3; zero behavior change for existing rows.
- **FE-R2** Aqua rows carry the optional `aqua` block fed by IDX-R5 (seam marked `PP-INTEGRATION-POINT`, wiring [POO-1065](https://linear.app/yeildbay/issue/POO-1065)).
- **FE-R3** `aquaStrategies` flag, default off; flag off hides every entry point; read via `isFeatureEnabled` only.
- **FE-R4** Manager schemas: `inRange`/`range` variant-specific; no Uniswap consumer breaks.
- **FE-R5** No Collect/Compound for the class; earnings = NAV growth.
- **FE-R6** Investor copy jargon-free; "cushioned", NEVER "protected"; illiquid state surfaced honestly (VLT-R5 path).
- **FE-R7** Missing real data = hide, never fake.
- **FE-R8** Invest = vault deposit; Withdraw = redeem; via `useWalletSignFlow` + `builtTxSchema` unchanged.
- **FE-R9** i18n in all 11 locales; no em dash in copy; TDD; Storybook; IDs registered.

---

## Open decisions (owner: Murilo, tracked on POO-1057)

| # | Decision | PROPOSED default | Blocks |
|---|---|---|---|
| D1 | ~~Repo location~~ RESOLVED (Murilo 2026-07-25): ONE new dedicated repo `pool-party-aqua` on Murilo's personal GitHub account. Only VISIBILITY pending (proposal public; needed by submission time + router copyleft) | Prepared locally at `~/Documents/pool-party-aqua`; GitHub creation after visibility confirmed | POO-1071 |
| D2 | ~~Backend during hackathon~~ RESOLVED (Murilo 2026-07-25): no backend service; Next server actions module + database (SRV rules) | n/a | n/a |
| D10 | Postgres for the app: reuse the existing Neon project (new `aqua_*` tables) or a fresh Neon project/branch | Fresh Neon project/branch; hackathon state isolated | POO-1071 |
| D3 | AMENDED for the 20h window (review, approved): seed **$50-200** own capital, maxTvl set accordingly; the $5k -> $20k / 48h schedule becomes the POST-event guarded launch | window seed $50-200 | POO-1062 |
| D4 | Fee numbers | protocol 5 bps/fill; flat 80 bps; perf 20% HWM; lockup 0d | first ship (POO-1062) |
| D5 | Mandate defaults | band spot-15%..-5%; epoch 7d; drift 10%; buffer 5%; coverage 1.0 | first ship |
| D6 | FE inside hackathon window | Yes, parallel, flag off | POO-1064/1067/1068 start |
| D7 | RESOLVED then AMENDED: **20 hours** to the demo; wave plan + cuts in `03_EXECUTION_PLAN.md` section 6 | n/a | all |
| D8 | RESOLVED (Murilo 2026-07-25): product name **Active Reserve** (formerly working name Party Notes 90/10). Official 280-char description in section FE below | n/a | copy in POO-1067 |
| D9 | Oracle params | maxPriceDecay 50 bps; maxStaleness 90 min | POO-1063 deploy, VLT-R4, KPR-R4 |
