# Active Reserve: Complete Execution Plan

**Date:** 2026-07-25
**Audience:** the whole hackathon team (humans and agent sessions). Share freely.
**Status:** all decisions resolved (D1-D10). Execution can start immediately.
**Deadline (D7 UPDATED 2026-07-25): 20 HOURS from kickoff.** The schedule in section 6 is a wall-clock wave plan for parallel sessions; the scope cuts in section 6.1 are in force and override any wider scope stated in the issues.
**Linear:** project [Aqua Strategies (1inch Hackathon)](https://linear.app/yeildbay/project/aqua-strategies-1inch-hackathon-bfbf16b06ef7) - epic [POO-1057](https://linear.app/yeildbay/issue/POO-1057)
**Repos:** on-chain side [github.com/0xmvercosa/pool-party-aqua](https://github.com/0xmvercosa/pool-party-aqua) (private now, PUBLIC at submission) - app side `pool-party-frontend`, branch `feat/aqua-poo-1057-hackathon`
**Companion docs (read before picking up any issue):** [00_ARCHITECTURE_AND_PLAN.md](./00_ARCHITECTURE_AND_PLAN.md) (architecture; read the Addenda block first), [01_BUSINESS_RULES.md](./01_BUSINESS_RULES.md) (numbered rules, single source of truth), [02_WORKPLAN.md](./02_WORKPLAN.md) (coordination protocol, frozen interfaces)

---

## 1. What we are building

**Active Reserve** (rule FE-R10), the first product of a new Aqua-powered strategy class:

> An always-earning reserve that buys the dip. Capital earns Aave lending yield every block and is deployed automatically the instant the market dips into the manager's buy band, purchasing ETH below market price. Objective: accumulate ETH at a discount while never sitting idle.

Mechanically: a ~200-line vault (the Aqua **maker**) holds pooled USDC. ~90% is supplied to Aave v3; ~10% backs a SwapVM program (official 1inch contracts, Aqua mode) quoting a buy band below spot. On a fill, a maker hook withdraws the exact USDC from Aave **inside the settlement transaction**, Aqua transfers it to the taker, and the purchased WETH lands back in the vault. Pool Party's protocol fee is pulled on-chain on every fill by a SwapVM fee opcode. Investors hold internal-ledger shares (no ERC-20 token); the manager creates and operates the strategy within platform guardrails compiled into the program by our own code.

Why judges should care: real production deployment on Arbitrum mainnet (not a fork), a genuine lending+market-making composition impossible on Uniswap v3, heavy SwapVM usage, and a modified SwapVM router (the explicitly-allowed scoring axis).

## 2. Locked decisions (all RESOLVED, full detail in 01_BUSINESS_RULES.md)

| # | Decision |
|---|---|
| D1 | One dedicated on-chain repo `pool-party-aqua` on `0xmvercosa` (private now, **flip to public at submission**, checklist in [POO-1070](https://linear.app/yeildbay/issue/POO-1070)) + frontend/app work in `pool-party-frontend` branch `feat/aqua-poo-1057-hackathon` |
| D2 | No separate backend. Next server-actions module + internal API module + Postgres (SRV rules v3) |
| D3 | Guarded launch: maxTvl **$5k**, raise to **$20k after 48h clean**; manager wallet = Murilo; our own capital only |
| D4 | Fees: protocol **5 bps per fill** (on-chain opcode), dip premium **80 bps** flat fee, performance **20% HWM**, lockup **0 days** |
| D5 | Mandate defaults: band **spot-15% to spot-5%**, epoch **3 days**, TVL-drift re-ship 10%, hot buffer 5% of USDC sleeve, coverage 1.0 (no over-commit in v1) |
| D6 | Frontend built on the separate branch during the event; merge to `main` post-hackathon |
| D7 | Demo **this week**; compressed priority ladder (section 6) |
| D8 | Product name **Active Reserve** + official 277-char description (FE-R10) |
| D9 | Oracle guard: maxPriceDecay **50 bps**, maxStaleness **90 min** (Chainlink ETH/USD, Arbitrum) |
| D10 | Database: **Neon mirror of prod** (created by Murilo). Credential ONLY in local `.env` files, never committed, rotate after the event, never commit mirror data |

## 3. Architecture in one page

**Two homes:**

- **`pool-party-aqua`** (this repo): `contracts/` Foundry (PartyVault, AaveV3Adapter, PartyRouter), deploy + fork-rehearsal scripts, canonical docs, submission artifacts (`VERIFIED.md`, `RUNBOOK.md`, `FILLS.md`).
- **`pool-party-frontend` @ `feat/aqua-poo-1057-hackathon`**: investor/manager surfaces AND the whole server side: thin server actions delegating to the **internal API module** `src/lib/aqua/api/` (plays pool-party-api's role: strategy persistence + on-chain orchestration + domain services: compiler, indexer/NAV, keeper logic, bot logic), Drizzle over the Neon prod mirror extended with `aqua_*` tables, and `scripts/aqua/` entrypoints (`pnpm aqua:keeper`, `pnpm aqua:taker`).

**On-chain flow (the demo money shot):** taker calls `swap()` on the router; the program runs `[deadline][AquaProtocolFeeAmountIn][flatFee][concentrate][salt]`; the `preTransferOut` maker hook fires, the vault unparks exact USDC from Aave (aUSDC burn); Aqua `pull` transfers USDC vault->taker; taker's WETH is `push`ed back to the vault and auto-compounds into the strategy's virtual balance. One transaction: Aave withdrawal + both real ERC-20 transfers + protocol fee capture.

**Cross-repo sync:** deployed addresses + ABIs flow from `pool-party-aqua` (`VERIFIED.md`) into the frontend branch's `src/lib/aqua/config.ts` as committed artifacts. Nothing imports across repos. Full detail: 02_WORKPLAN.md.

## 4. Lanes and suggested ownership

Five lanes run in parallel. One session/person = one issue = one branch (`<type>/aqua-poo-<num>-<slug>`), PR per issue, honest incremental commits (history is judged, qualification rule 3).

| Lane | Issues | Profile |
|---|---|---|
| A. Chain truth + launch | [POO-1058](https://linear.app/yeildbay/issue/POO-1058), [POO-1062](https://linear.app/yeildbay/issue/POO-1062), [POO-1070](https://linear.app/yeildbay/issue/POO-1070) | Infra/lead; Murilo signs all mainnet txs (D3) |
| B. Server module | [POO-1071](https://linear.app/yeildbay/issue/POO-1071), [POO-1061](https://linear.app/yeildbay/issue/POO-1061), [POO-1069](https://linear.app/yeildbay/issue/POO-1069) | TypeScript, SDKs, Drizzle |
| C. Contracts | [POO-1059](https://linear.app/yeildbay/issue/POO-1059), [POO-1060](https://linear.app/yeildbay/issue/POO-1060), [POO-1063](https://linear.app/yeildbay/issue/POO-1063) | Solidity + Foundry |
| D. Flow + accounting | [POO-1066](https://linear.app/yeildbay/issue/POO-1066), [POO-1065](https://linear.app/yeildbay/issue/POO-1065) | TypeScript, viem, events |
| E. Product UI | [POO-1064](https://linear.app/yeildbay/issue/POO-1064), [POO-1067](https://linear.app/yeildbay/issue/POO-1067), [POO-1068](https://linear.app/yeildbay/issue/POO-1068) | Pool Party frontend patterns |

## 5. Issue-by-issue plan

Every issue body carries its numbered rules, acceptance criteria, and a "Structure v3" comment that supersedes the body preamble where they conflict. Read the issue AND its latest comment.

### P0 - Ground truth

**[POO-1058](https://linear.app/yeildbay/issue/POO-1058) - Verify official Aqua/SwapVM deployments on Arbitrum + fork rehearsal** (1d, URGENT, blocks the launch)
Resolve the address discrepancy between the aqua README, the SDK constants, and the swap-vm README on Arbiscan (bytecode diff + usage evidence). Then rehearse the full loop on an anvil fork with an EOA maker: approve -> ship BOTH tokens (WETH at 0) -> quote -> one swap -> events -> dock, using the SDK e2e specs as templates. Prove the `preTransferOut` hook fires in Aqua mode with a stub maker. Rules 1058-R1..R3: no mainnet approve before this is Done; verified addresses become the single shared config; the rehearsal must exercise the two known traps (terminal curve ordering, both-tokens ship). Deliverable: `VERIFIED.md` + reproducible `pnpm rehearse` script in this repo.

### P1 - Foundation and launch

**[POO-1071](https://linear.app/yeildbay/issue/POO-1071) - Scaffolds: this repo + frontend branch module** (0.5-1d, URGENT, blocks B and E lanes)
Two scaffolds. (a) This repo: Foundry init under `contracts/`, script harness. (b) Frontend branch: `src/lib/aqua/api/` skeleton with `server-only` guards, thin action stubs, Drizzle pointed at the Neon prod mirror (`AQUA_DATABASE_URL` in `.env.local`, already placed locally), schema introspection + `aqua_*` extension migrations (`aqua_mandates`, `aqua_ships`, `aqua_fills`, `aqua_nav_snapshots`, `aqua_keeper_log`), `scripts/aqua/` entrypoints, address config stub. Rules SRV-R1..R6 (v3). Keep it SMALL and land fast.

**[POO-1059](https://linear.app/yeildbay/issue/POO-1059) - PartyVault contract + Foundry tests** (1.5-2d, URGENT)
The Aqua maker and the only pooled-custody contract. Internal share ledger with OZ ERC-4626 math (VLT-R1, decimals offset anti-inflation), manager seeds first (VLT-R2), no ERC-20 (VLT-R3), NAV with Chainlink staleness gate (VLT-R4), USDC-only redemption with `InsufficientLiquidUsdc` (VLT-R5), lockup param (VLT-R6), MANAGER/KEEPER roles with no fund-exfiltration path (VLT-R7), 20% HWM performance fee as minted shares (VLT-R8), `onPreTransferOut` JIT hook endpoint (VLT-R9), manager-only caps (VLT-R10), `dockAll()` emergency stop (VLT-R11). Consumes the FROZEN `ICarryAdapter` interface. Tests: inflation-attack properties, role fuzzing, cap enforcement, staleness and liquidity gates, HWM across gain/loss, dockAll.

**[POO-1060](https://linear.app/yeildbay/issue/POO-1060) - AaveV3Adapter + JIT hook path + fork tests** (0.5-1d, HIGH)
~50 lines implementing the frozen `ICarryAdapter` (`park`/`unpark`/`parkedBalance`), vault-only access (ADP-R1), exact-amount withdraw bubbling Aave's revert as "temporarily illiquid" (ADP-R2), interest-inclusive balance (ADP-R3), no admin/rescue functions (ADP-R5). Fork tests include the full JIT path with a stub vault (hook -> unpark -> transfer in one tx) and a utilization-stress revert scenario. PR must include a gas note for the JIT fill (min-fill economics).

**[POO-1061](https://linear.app/yeildbay/issue/POO-1061) - Program compiler + ship/roll/dock** (1-1.5d, HIGH; blocked by 1071)
Home: `src/lib/aqua/api/compiler/` on the frontend branch, CLI wrappers in `scripts/aqua/`. The ONLY producer of programs and ship/dock calldata: canonical order `[deadline][AquaProtocolFeeAmountIn][flatFeeAmountInXD][concentrateGrowLiquidity2D][salt]` (PRG-R1; curves are TERMINAL), both tokens always shipped with empty side 0 (PRG-R2), band fully below spot vs Chainlink (PRG-R3), 3-day epoch deadline + epoch-id salt (PRG-R4), sleeve/cap sizing (PRG-R5), coverage 1.0 (PRG-R6), D4 fees baked in (PRG-R7), roll = dock+ship batched (PRG-R8). Frozen mandate shape and `compile()` return shape are law (02_WORKPLAN section "Frozen interfaces"). Unit tests: decode round-trips + one failing-input test per guardrail.

**[POO-1062](https://linear.app/yeildbay/issue/POO-1062) - Arbitrum mainnet deploy + guarded launch** (0.5-1d once blockers close; blocked by 1058, 1059, 1060, 1061, 1071)
Deploy adapter + vault (verified on Arbiscan, source published), set D3 caps (maxTvl $5k, maxPerShip 10% TVL, router allowlist = official router only, tokens USDC/WETH), Murilo seeds, first ship through the compiler with D4/D5 params, smoke test (`quote()` at 3 sizes + `rawBalances` match), record everything in `RUNBOOK.md` + `VERIFIED.md`. After this issue Active Reserve EXISTS on mainnet: earning Aave carry, quoting the band, protocol fee live.

### P2 - Real flow, accounting, operations

**[POO-1066](https://linear.app/yeildbay/issue/POO-1066) - Taker MVP + arb bot vs Uniswap** (1-1.5d, HIGH; live part blocked by 1062, fork dev before)
Home: `scripts/aqua/taker.ts`. MVP first: dry-run quote mode + single scripted fill (BOT-R1); this produces the qualification-critical real fills, including at least one larger than the hot buffer so the JIT Aave path fires (the money-shot trace). Arb mode (BOT-R2: execute only when profit > gas + margin vs Uniswap v3) is the stretch. Caps and separate bot wallet (BOT-R3/R4); every fill hash appended to `FILLS.md` (BOT-R5). Target: >= 3 real mainnet fills logged.

**[POO-1065](https://linear.app/yeildbay/issue/POO-1065) - Indexer + NAV + 90/10 attribution** (1-1.5d, HIGH; blocked by 1071, live by 1062)
Home: `src/lib/aqua/api/indexer/`. Ingest Aqua `Shipped/Docked/Pushed/Pulled`, router `Swapped`, vault `Deposited/Redeemed` (IDX-R1) into the mirror DB; live money display always from fresh reads (IDX-R2); share price must equal on-chain `convertToAssets` within rounding (IDX-R3); attribution carry vs fill P&L vs premium, daily + per-epoch (IDX-R4); outputs feed the UI through the API module and a human-readable demo report (IDX-R5); transaction-display rule applies (IDX-R6). Golden test replaying the P0 rehearsal fixture.

**[POO-1069](https://linear.app/yeildbay/issue/POO-1069) - Keeper suite** (1-1.5d, HIGH; blocked by 1061 + 1071)
Home: `scripts/aqua/keeper.ts` over the API module, logging to `aqua_keeper_log`. Compressed scope first: **roll keeper** (3-day epochs make it demo-visible, KPR-R1) and **price sentinel** (KPR-R4: dock on Chainlink staleness > 90 min or band breach; this is the ONLY price protection until PartyRouter lands, treat as critical). Then drift re-ship (KPR-R2), coverage sentinel (KPR-R3), re-park sweep (KPR-R5). Full audit logging (KPR-R6), stop-on-unexpected-revert (KPR-R7). Fork tests simulate each rule.

**[POO-1070](https://linear.app/yeildbay/issue/POO-1070) - Demo runbook + submission package** (0.5-1d spread across the week; blocked by 1065 + 1066)
The submission repo IS `pool-party-aqua`. Demo script (5-8 min): pitch -> live Arbiscan (vault, aUSDC accruing) -> the single-tx money shot (aUSDC burn + Pulled + push + protocol fee) -> attribution report -> PartyRouter one-screen diff + rejected under-priced fill (if 1063 lands) -> roll vs Uniswap burn/swap/mint comparison. README with reproduction steps + qualification mapping + license notes. Checklist: **flip repo to PUBLIC**, secret/data scan before flipping (gitleaks), backup screen recording, commit-history hygiene check. START THE README AND RECORDING EARLY.

### P3 - Modified SwapVM (conditional cut)

**[POO-1063](https://linear.app/yeildbay/issue/POO-1063) - PartyRouter: OraclePriceAdjuster wired + tests + migration** (2-3d; dev unblocked from Day 0, migration blocked by 1062)
The scoring axis: official SwapVM redeployed with ONE instruction wired (upstream `OraclePriceAdjuster` exists complete but has no opcode slot and no tests). Diff must fit on one screen (RTR-R1); we write the missing tests: quote/swap parity, staleness revert, decay clamp both directions, fuzz (RTR-R2); D9 params (RTR-R3); source published, Arbiscan-verified (RTR-R4); migration = allowlist + roll onto an oracle-guarded program, official router stays as fallback (RTR-R5); compiler emits the opcode only for this router (RTR-R6); capture one rejected under-priced fill (RTR-R7). **If the week runs short, this is the first cut**: the price sentinel (1069) is the documented fallback; the product remains fully valid on the official router.

### P4 - Product UI (frontend branch, behind `aquaStrategies` flag)

**[POO-1064](https://linear.app/yeildbay/issue/POO-1064) - Schema discriminator + flag + services** (0.5-1d, blocks 1067/1068)
Original body applies (frontend repo): `protocol: "uniswap-v3" | "aqua"` on `strategySchema` (FE-R1, absent = uniswap-v3, zero regression), optional `aqua` block fed by the internal API module (FE-R2), `aquaStrategies` flag default off gating every entry point (FE-R3), manager schema variants (FE-R4), no Collect/Compound for the class (FE-R5), realistic fixtures (FE-R6), hide-never-fake (FE-R7). Land small and first.

**[POO-1067](https://linear.app/yeildbay/issue/POO-1067) - Investor surface** (2-3d full, MINIMAL CUT for the week; blocked by 1064)
Minimal cut per D7: strategy detail page + Invest (vault deposit) + Withdraw (redeem) working end-to-end through `useWalletSignFlow` + `builtTxSchema` (FE-R8), with the **Active Reserve** name + official description verbatim (FE-R10), sleeves + band visual + epoch countdown, on-chain verification block, honest "temporarily illiquid" state, disclosure block ("cushioned", never "protected", FE-R6/R9). Attribution chart and polish only if time allows.

**[POO-1068](https://linear.app/yeildbay/issue/POO-1068) - Manager surface** (2d, CONDITIONAL CUT; blocked by 1064)
Mandate form (frozen shape) + compiled review + manage view (band vs price, coverage, epoch countdown, Roll CTA, fills feed, Dock-all). Per D7 this is built only after 1067's minimal cut; CLI ship/roll/dock is the accepted manager demo path.

## 6. The 20-hour wave plan (wall-clock, parallel sessions)

### 6.1 Scope cuts in force (override issue bodies)

- **CUT entirely**: [POO-1063](https://linear.app/yeildbay/issue/POO-1063) PartyRouter (fallback: manual ops + honest note in the demo that the oracle guard is the designed next step; the sentinel story becomes "manager watch + dockAll", documented in the runbook), [POO-1068](https://linear.app/yeildbay/issue/POO-1068) manager UI (CLI ship/roll/dock IS the manager demo), [POO-1069](https://linear.app/yeildbay/issue/POO-1069) keeper loop (all ops manual via CLI during the window; the 3-day epoch will not elapse anyway; the "roll" demo is one manual dock+ship showing the two-accounting-writes magic), arb mode of the bot (BOT-R2), [POO-1064](https://linear.app/yeildbay/issue/POO-1064) main-app schema work.
- **REDUCED**: [POO-1065](https://linear.app/yeildbay/issue/POO-1065) indexer becomes a **status/report script** (`pnpm aqua:status`): reads `rawBalances`, `parkedBalance`, wallet balances, decodes recent `Pulled/Pushed/Swapped` logs, prints NAV + a simple carry-vs-fills attribution. No DB-backed series. [POO-1071](https://linear.app/yeildbay/issue/POO-1071) Drizzle scope shrinks to TWO tables (`aqua_ships`, `aqua_fills`); mirror introspection deferred. [POO-1059](https://linear.app/yeildbay/issue/POO-1059) keeps all rules but test depth targets the essentials: share-math properties (inflation attack), role boundaries, caps, JIT hook path.
- **STRETCH ONLY (zero critical path)**: [POO-1067](https://linear.app/yeildbay/issue/POO-1067) as ONE ultra-minimal page (vault views + Deposit/Redeem buttons) only if a dedicated session runs it fully in parallel; the demo qualifies with scripts alone per the hackathon brief ("test scripts or UI").
- **UNCHANGED**: [POO-1058](https://linear.app/yeildbay/issue/POO-1058), [POO-1060](https://linear.app/yeildbay/issue/POO-1060), [POO-1061](https://linear.app/yeildbay/issue/POO-1061), [POO-1062](https://linear.app/yeildbay/issue/POO-1062), [POO-1066](https://linear.app/yeildbay/issue/POO-1066) MVP, [POO-1070](https://linear.app/yeildbay/issue/POO-1070).
- **ADDED (approved)**: a second **demo band mandate** (spot-1%..-0.2%, same fees/epoch, distinct salt) shipped at launch so stage fills execute near market and the demo shows one vault backing two simultaneous strategies with the same capital. Demo honesty framing: our own taker generates the fills to demonstrate the machine; Aave carry is the external, real yield in the window; in production the premium is paid by arbitrageurs when price enters the band and by 1inch-routed flow once aggregation integrates Aqua.

### 6.2 Waves

| Window | Goal | In flight (parallel) |
|---|---|---|
| **T+0 to T+3** | Ground truth + skeletons + Solidity underway | [1058](https://linear.app/yeildbay/issue/POO-1058) verify/rehearsal; [1071](https://linear.app/yeildbay/issue/POO-1071) minimal scaffolds; [1059](https://linear.app/yeildbay/issue/POO-1059) vault; [1060](https://linear.app/yeildbay/issue/POO-1060) adapter |
| **T+3 to T+8** | Rehearsal green; contracts tested; compiler done; taker ready on fork | finish 1058/1071; 1059/1060 tests; [1061](https://linear.app/yeildbay/issue/POO-1061) compiler + CLI; [1066](https://linear.app/yeildbay/issue/POO-1066) taker on fork; [1070](https://linear.app/yeildbay/issue/POO-1070) README skeleton |
| **T+8 to T+12** | **MAINNET LAUNCH** | [1062](https://linear.app/yeildbay/issue/POO-1062): deploy, verify, caps, seed, TWO ships (production band spot-15%..-5% AND the approved **demo band spot-1%..-0.2%**, combined shipped USDC within the 10% sleeve per PRG-R5/R6), smoke test; then 1066 first real fills on the demo band including one bigger than the hot buffer (the JIT money-shot trace) |
| **T+12 to T+17** | Evidence accumulation + ops demo | more fills into `FILLS.md`; manual roll demo (dock+ship); [1065](https://linear.app/yeildbay/issue/POO-1065) status/attribution report; 1067 stretch page if staffed; 1070 runbook writing |
| **T+17 to T+20** | Package + dry run | recording, submission checklist, secret scan, flip-to-public decision, full demo dry run, buffer |

**Gate rule (every ~3h checkpoint):** any red item in {1058, 1071, 1059, 1060, 1061, 1062, 1066-MVP, 1070} immediately pulls every session off reduced/stretch work. The single hard milestone is the launch wave at T+8: if blockers are not closing by T+6, cut vault test depth further (keep inflation + roles + JIT) rather than slipping the launch.

## 7. Coordination protocol (summary; canonical in 02_WORKPLAN.md)

1. One session = one issue = one branch; PR per issue; squash-merge; never commit to `main`/integration branch directly; commits `<type>(aqua): <description>`; honest incremental history (judged).
2. **Frozen interfaces are law** (change requires an epic comment + Murilo ack): `ICarryAdapter`; the vault external surface; the mandate shape; the canonical program order; `compile()` return shape; the `aqua_*` table names.
3. **Addresses from one place only**: `VERIFIED.md` -> `src/lib/aqua/config.ts`. A hardcoded address anywhere else is a review-blocking defect.
4. **Rules drift = STOP**: comment on the issue + epic, wait for Murilo, bump `rules:vN` everywhere on change. Never silently deviate. On divergence between an issue and `01_BUSINESS_RULES.md`, the doc wins.
5. Docs land with the PR that makes them true (`VERIFIED`/`RUNBOOK`/`FILLS` + rule re-syncs).
6. Internalize the two upstream traps: curve instructions are TERMINAL (fees after the curve silently never apply) and one-sided strategies still ship BOTH tokens (empty side amount 0).
7. **Mainnet discipline**: nothing touches mainnet before 1058 is Done; only 1062 (and 1063 migration) send privileged txs; Murilo holds the manager key; keeper and bot use their own separate, small-balance keys.
8. English everywhere; no em dash anywhere.

## 8. Qualification mapping (hackathon rules)

| Requirement | How we satisfy it | Proof artifact |
|---|---|---|
| Custom Aqua app, sophisticated DeFi position | PartyVault (pooled maker) + Active Reserve program: lending + market making with JIT settlement | Contracts + `VERIFIED.md` ([POO-1059](https://linear.app/yeildbay/issue/POO-1059)/[1062](https://linear.app/yeildbay/issue/POO-1062)) |
| SwapVM usage (scores higher) + allowed modified redeploy | Strategy IS a SwapVM program in Aqua mode; PartyRouter wires the upstream-unwired oracle instruction | Program decode in runbook; one-screen router diff ([POO-1063](https://linear.app/yeildbay/issue/POO-1063)) |
| On-chain execution of token transfers in the demo | Real mainnet fills, including one JIT trace (aUSDC burn + Pulled + push in one tx) | `FILLS.md` + tx hashes ([POO-1066](https://linear.app/yeildbay/issue/POO-1066)) |
| Proper git commit history | PR per issue, phased commits since Day 0 in both repos | Repo history ([POO-1070](https://linear.app/yeildbay/issue/POO-1070) hygiene check) |

## 9. Security rails (non-negotiable)

- The Neon prod-mirror credential lives ONLY in local `.env` files (already placed; gitignored in both homes). Never in code, docs, Linear, or commits. **Rotate it after the hackathon.** No data from the mirror is ever committed anywhere (this repo goes public).
- Key separation: manager key (Murilo, signs deploy/ship/roll), keeper key (bounded re-issue only, no fund path), bot key (own small funds). Compromise blast radius per key is documented in 00_ARCHITECTURE section 5.
- Caps are the answer to the unaudited upstream stack (Dev Preview, no audits found): $5k TVL, per-ship cap, allowlists, `dockAll()` + approve-revoke as the emergency stop (runbook R5 of [POO-1062](https://linear.app/yeildbay/issue/POO-1062)).
- Secret scan (gitleaks) before flipping the repo public ([POO-1070](https://linear.app/yeildbay/issue/POO-1070) checklist).

## 10. Top risks and mitigations

| Risk | Mitigation |
|---|---|
| Address ambiguity upstream (README vs SDK) | [POO-1058](https://linear.app/yeildbay/issue/POO-1058) resolves on Day 0 before any approve; fallback = deploy official source |
| Week too short | Priority ladder (section 6); first cut is [POO-1063](https://linear.app/yeildbay/issue/POO-1063), second is [POO-1068](https://linear.app/yeildbay/issue/POO-1068); CLI is the manager demo path |
| No organic taker flow on Aqua yet | Our own taker bot generates real, honest fills; arb-vs-Uniswap makes them economic ([POO-1066](https://linear.app/yeildbay/issue/POO-1066)) |
| Vault share-math bugs (inflation attack) | OZ 4626 math + decimals offset + manager-seeds-first + property tests ([POO-1059](https://linear.app/yeildbay/issue/POO-1059)) |
| Price protection gap until router lands | Price sentinel keeper is critical-path ([POO-1069](https://linear.app/yeildbay/issue/POO-1069) KPR-R4) |
| Aave utilization spike blocks JIT | Hot buffer + pull-revert = illiquid-not-insolvent + honest UI state ([POO-1060](https://linear.app/yeildbay/issue/POO-1060) ADP-R2, [POO-1067](https://linear.app/yeildbay/issue/POO-1067) FE-R5) |
| Fork-frozen Chainlink in tests | Mock aggregator / storage poke in fork tests only; production feeds update normally ([POO-1063](https://linear.app/yeildbay/issue/POO-1063)) |

## 11. Definition of done (20-hour window)

1. Active Reserve live on Arbitrum mainnet under D3 caps with >= 3 real fills logged, at least one exercising the JIT Aave path (aUSDC burn + `Pulled` + `push` in one tx).
2. One manual roll executed live (dock + ship) proving the two-accounting-writes re-range.
3. `pnpm aqua:status` report showing NAV + carry-vs-fills attribution from live chain data.
4. Demo runbook + recording done; submission checklist ticked; secret scan clean; repo flipped public; commit history phased across both repos.
5. Consciously-cut items (PartyRouter, keepers, manager UI, arb mode) named honestly in the README as designed next steps, with the manual-ops fallback documented in the runbook.
6. Post-event epilogue: strategies docked, caps to zero, DB credential rotated, decisions log closed on [POO-1057](https://linear.app/yeildbay/issue/POO-1057).
