# Aqua Strategies: Business Rules (v1)

**Date:** 2026-07-25
**Status:** v1. Rules marked with a decision tag (D3, D4, D5, D9) use PROPOSED defaults until Murilo confirms on the epic [POO-1057](https://linear.app/yeildbay/issue/POO-1057). Any rule change after confirmation increments the version here, on the issue labels (`rules:vN`), and in file headers, per the project's rule-versioning discipline.
**Scope:** single source of truth for all numbered rules of the Aqua hackathon build. Each Linear issue embeds its own subset verbatim; on divergence, THIS FILE wins and the issue must be re-synced. Canonical home: `docs/` of this dedicated hackathon repo.

Component prefixes: VLT (PartyVault), ADP (carry adapter), SRV (server module + database), PRG (program compiler), KPR (keepers), BOT (taker bot), IDX (indexer/NAV), RTR (PartyRouter), FE (frontend). Cross-references use `VLT-R4` style.

> **Addendum (Murilo, 2026-07-25):** there is NO separate backend service. All orchestration runs as a server-only module inside this Next app (server actions + scripts), which implies Next persists state in a database. See SRV rules.

---

## VLT: PartyVault ([POO-1059](https://linear.app/yeildbay/issue/POO-1059))

- **VLT-R1** Deposits are USDC only. Shares minted with OpenZeppelin ERC-4626 math internally (same conversion formulas, rounding down, decimals offset +3 anti-inflation). Deposit reverts if resulting TVL > `maxTvl`.
- **VLT-R2** The first deposit must come from the MANAGER address (manager seed); other deposits revert until seeded.
- **VLT-R3** No ERC-20 share token: internal `mapping(address => shares)`, no Transfer events, transfers impossible by construction. Public views `sharesOf`, `convertToShares`, `convertToAssets`, `totalAssets`; events `Deposited(investor, assets, shares)`, `Redeemed(investor, assets, shares)`.
- **VLT-R4** `totalAssets` = wallet USDC + `adapter.parkedBalance(USDC)` + wallet WETH valued at Chainlink ETH/USD. Feed stale beyond `maxStaleness` (D9: 90 min PROPOSED) makes deposit and redeem revert. No NAV without a fresh price.
- **VLT-R5** Redemption burns shares, pays USDC only. Insufficient liquid USDC (buffer + parked) reverts with `InsufficientLiquidUsdc`. No in-kind payout in v1.
- **VLT-R6** Lockup `lockupDays` per vault param (D4: 0 days PROPOSED for hackathon); early redeem reverts.
- **VLT-R7** Roles: MANAGER and KEEPER may call `execShip` / `execDock` / `dockAll` only, restricted to allowlisted routers and tokens, per-token ship amount <= `maxPerShip`. No role has a path that transfers funds to an arbitrary address. No upgradability. No pause-and-take.
- **VLT-R8** Performance fee `perfFeeBps` (D4: 20% PROPOSED) on share-price high-water mark, accrued as newly minted shares to MANAGER on deposit / redeem / `accrueFee()`. Global HWM is sound because shares are non-transferable. Protocol fee lives in the program (PRG-R7), not the vault.
- **VLT-R9** `onPreTransferOut(token, amount)` callable only by an allowlisted router during settlement; unparks the shortfall beyond the hot buffer. Sweep back to adapter is keeper-driven (KPR-R5).
- **VLT-R10** Caps (`maxTvl`, `maxPerShip`, allowlists, buffer target) adjustable by MANAGER only.
- **VLT-R11** `dockAll()` docks every active strategy; MANAGER or KEEPER; accounting-only emergency stop.

## ADP: Carry adapter ([POO-1060](https://linear.app/yeildbay/issue/POO-1060))

- **ADP-R1** `park` / `unpark` callable only by the owning vault.
- **ADP-R2** `unpark(token, amount)` withdraws exactly `amount` from Aave v3; bubbles Aave's revert on utilization stress. The vault treats that revert as temporarily illiquid, never bad debt.
- **ADP-R3** `parkedBalance` returns interest-inclusive aToken balance (continuous accrual in `totalAssets`).
- **ADP-R4** Adapter holds aTokens only; never more than transient underlying during park/unpark.
- **ADP-R5** No admin or rescue functions in v1; replacement = new vault deployment.
- Frozen interface: `park(address,uint256)`, `unpark(address,uint256)`, `parkedBalance(address) returns (uint256)`.

## SRV: Server module + database ([POO-1071](https://linear.app/yeildbay/issue/POO-1071)) - **v2** (refined by Murilo 2026-07-25: internal API module + DB mirrors the real API)

- **SRV-R1 (v2)** Strict layering, three tiers, all inside this Next app: (1) thin **server actions** (input validation + session/auth only, zero business logic); (2) the **Aqua API module** (`src/lib/aqua/api/`, server-only), which plays the role of pool-party-api for this app: saves strategies/mandates to the database, orchestrates on-chain calls (sends keeper/bot txs with server-side keys; returns BuiltTx payloads for anything a wallet must sign), and hosts the domain services (compiler, indexer/NAV, keeper logic, bot logic); (3) infra clients (Drizzle, viem). The API module is the ONLY layer allowed to touch Drizzle or viem. No separate backend service exists.
- **SRV-R2 (v2)** The database MIRRORS the pool-party-api domain model wherever domains overlap (strategies catalog, positions/holdings, activity events), so post-hackathon migration to the real API is a module swap, not a rewrite. Aqua-specific tables extend that mirrored core: `aqua_ships` (strategyHash, program bytes, epoch, status), `aqua_fills`, `aqua_nav_snapshots`, `aqua_keeper_log`. Drizzle migrations; money columns as numeric strings (never JS float).
- **SRV-R3** Long-running processes (keeper loop, taker bot) execute the SAME server module via repo scripts (`pnpm aqua:keeper`, `pnpm aqua:taker`, tsx), not inside request handlers. A route handler + external cron is an accepted later alternative; Vercel cron is NOT assumed (real mode deploys to AWS dev).
- **SRV-R4** Keeper key, bot key, and RPC URLs are server env only; never `NEXT_PUBLIC_*`; never imported client-side.
- **SRV-R5** Anything a wallet signs (manager or investor) is returned by a server action as a `builtTxSchema`-validated payload consumed by `useWalletSignFlow`, matching the existing trust boundary.
- **SRV-R6** Solidity contracts (PartyVault, adapter, PartyRouter) live in this same repo under `contracts/` (Foundry workspace), outside the Next module boundary (D1 resolved: one dedicated repo for everything).

## PRG: Program compiler ([POO-1061](https://linear.app/yeildbay/issue/POO-1061))

- **PRG-R1** Canonical program order, always: `[deadline][AquaProtocolFeeAmountIn][flatFeeAmountInXD][concentrateGrowLiquidity2D][salt]`. Curve instructions are TERMINAL; a fee emitted after the curve is a bug (silently never applied).
- **PRG-R2** Ship registers BOTH tokens; empty side ships amount 0 (upstream reverts otherwise).
- **PRG-R3** Band entirely below spot at build time: `bandHigh <= chainlinkSpot * 0.98`; compiler refuses otherwise.
- **PRG-R4** `deadline` = epoch end (D5: 7 days PROPOSED); `salt` = epoch id (docked strategyHash is dead forever).
- **PRG-R5** Shipped USDC <= min(`maxPerShip`, `bandSleevePct` x totalAssets) (D5: 10% PROPOSED).
- **PRG-R6** Coverage v1 = 1.0: sum of shipped USDC across active strategies <= vault total USDC. No over-commit in v1 (SLAC deferred to later products).
- **PRG-R7** Program fees per D4 (PROPOSED: protocol 5 bps to treasury via `AquaProtocolFeeAmountIn`; flat fee 80 bps dip premium). Only allowlisted routers as `app`.
- **PRG-R8** Roll = `dock(old) + ship(new)` batched in one action.
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
- **BOT-R2** Arb mode executes only when `expectedProfit > gasCost + marginBps`; logs every decision.
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
- **RTR-R3** Params per D9 (PROPOSED: maxPriceDecay 50 bps, maxStaleness 90 min). Feed address is a program argument.
- **RTR-R4** Source published (Degensoft copyleft + hackathon requirement); Arbiscan-verified.
- **RTR-R5** Migration: allowlist PartyRouter in the vault, roll live strategy onto an oracle-guarded program; official router stays allowlisted as fallback during the hackathon.
- **RTR-R6** Compiler emits the oracle instruction only when targeting PartyRouter.
- **RTR-R7** Demo evidence: one rejected under-priced fill captured.

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
| D3 | Launch capital + cap schedule | maxTvl $5k -> $20k after 48h clean; manager wallet = Murilo | POO-1062 |
| D4 | Fee numbers | protocol 5 bps/fill; flat 80 bps; perf 20% HWM; lockup 0d | first ship (POO-1062) |
| D5 | Mandate defaults | band spot-15%..-5%; epoch 7d; drift 10%; buffer 5%; coverage 1.0 | first ship |
| D6 | FE inside hackathon window | Yes, parallel, flag off | POO-1064/1067/1068 start |
| D7 | Hackathon final demo date | UNKNOWN, needed for scheduling | POO-1070 |
| D8 | Product name | "Party Notes 90/10" working name | copy in POO-1067 |
| D9 | Oracle params | maxPriceDecay 50 bps; maxStaleness 90 min | POO-1063 deploy, VLT-R4, KPR-R4 |
