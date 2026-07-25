# Kickoff: 2 parallel tracks, 20-hour window

**Date:** 2026-07-25. Clock starts at kickoff (T+0).
**Staffing:** 2 workers (members or agent sessions): **Track A (contracts)** and **Track B (TypeScript rails)**. Murilo is the manager-key holder and approver (not counted as a track).
**Read before writing any code:** [VERIFIED.md](./VERIFIED.md) (addresses, pinned source, confirmed traps), [01_BUSINESS_RULES.md](./01_BUSINESS_RULES.md) (rules v2 + window-cut notes), [03_EXECUTION_PLAN.md](./03_EXECUTION_PLAN.md) section 6 (cuts in force), your Linear issue AND its latest comments (latest comment supersedes the body).

## Shared rules of engagement (both tracks)

1. Repos: public `github.com/0xmvercosa/pool-party-aqua` (contracts, scripts, docs; history is judged) and `pool-party-v2-frontend` branch `feat/aqua-poo-1057-hackathon` (API module, compiler, UI). One issue = one branch = one PR; branch `<type>/aqua-poo-<num>-<slug>`; commit `<type>(aqua): <description>`.
2. **Commit AND push after every green step.** Continuous push timestamps are part of the submission. Never backdate, never squash the day away.
3. Frozen interfaces (change requires an epic comment + Murilo ack): `ICarryAdapter{park,unpark,parkedBalance}`; vault surface `deposit/redeem/sharesOf/convertTo*/totalAssets/execShip/execDock/dockAll/preTransferOut` (measured 9-arg hook); mandate shape; program order v3 (measured) `[deadline][concentrateGrowLiquidity2D][flatFeeAmountInXD 80bps][xycSwapXD][salt]`; `compile()` return; tables `aqua_ships`/`aqua_fills`.
4. **Mainnet discipline:** nothing touches mainnet until POO-1058 is Done. Only Murilo's manager key deploys, seeds, and ships. The taker uses its own small-balance wallet. Gen-2 addresses only (VERIFIED.md).
5. Secrets in local `.env` only. No em dash anywhere. English everywhere. Linear: move your issue to In Progress when starting, In Review with PR link when done (never Done).
6. Checkpoint every ~3h on the epic (one-line comment: done / in flight / blocked). Any red critical item pulls both tracks onto it.

## Track A: contracts (owner: member/agent 1)

**Sequence: POO-1059 (vault) -> POO-1060 (adapter) -> co-own POO-1062 (launch).**

1. In `pool-party-aqua`: branch `feat/aqua-poo-1059-partyvault`. Initialize Foundry under `contracts/` (OZ + forge-std; this is the contracts half of POO-1071, you own it).
2. Build **PartyVault demo-minimum** exactly per the VLT window-cut note in 01_BUSINESS_RULES: 4626 math + decimals offset (VLT-R1), manager seeds first (R2), internal ledger + views + events (R3), USDC-only redeem with `InsufficientLiquidUsdc` (R5), `execShip`/`execDock` under a SINGLE owner, the measured `preTransferOut` JIT hook restricted to the gen-2 router (R9), `maxTvl` only (R10), `dockAll` (R11). DO NOT build: staleness gate, lockup, keeper role, HWM fee, maxPerShip, token allowlist (deferred, README-documented).
3. Test essentials only: inflation/first-depositor property test, owner gating fuzz, maxTvl, redeem liquidity gate, dockAll. Use a stub `ICarryAdapter`.
4. Then `feat/aqua-poo-1060-aave-adapter`: AaveV3Adapter (~50 lines) + Arbitrum-fork tests: park/unpark exactness, vault-only access, aUSDC accrual over warp, utilization-stress revert, and the full JIT path (stub vault: hook -> unpark -> transfer in ONE tx). Include the gas note for a JIT fill in the PR.
5. Publish ABIs as JSON artifacts in the repo the moment they stabilize; ping Track B.
6. At S2 (see sync points): drive POO-1062 with Murilo signing: deploy adapter + vault, Arbiscan verify, set maxTvl, seed $50-200, then execute the two ships built by Track B (production band + demo band). Record everything in `RUNBOOK.md` + `VERIFIED.md`.

## Track B: TypeScript rails (owner: member/agent 2)

**Sequence: POO-1058 (rehearsal) -> POO-1071 TS scaffolds -> POO-1061 (compiler) -> POO-1066 (taker) -> POO-1065 (status) -> POO-1067 (page, only if time).**

1. In `pool-party-aqua`: branch `chore/aqua-poo-1058-rehearsal`. Set up the pnpm workspace (`scripts/`, tsx, viem, `@1inch/swap-vm-sdk@0.3.0` + `@1inch/aqua-sdk@0.2.0` pinned EXACT, no caret). Anvil fork of Arbitrum. Rehearse the full loop with an EOA maker against the gen-2 pair: approve -> build the program per PRG-R1 v3 via `AquaProgramBuilder` ONLY -> ship BOTH tokens (WETH amount 0) -> `quote()` -> one `swap()` -> decode `Pulled/Pushed/Swapped` -> `dock`.
2. While there, close the four VERIFIED.md checkboxes: (a) builder round-trip vs live ship #0 (`0xa966fc93...`); (b) is `protocolFeeAmountOutXD` (fee on tokenOut = USDC) present in the deployed array AND buildable via the SDK? If yes, tell Murilo: the on-chain protocol fee returns, charged in USDC; (c) hook firing with a stub maker; (d) are the 4 gen-2 makers EOAs (demo claim)? Commit `VERIFIED.md` updates + the reproducible `pnpm rehearse`.
3. In the frontend worktree (branch `feat/aqua-poo-1057-hackathon`): POO-1071 TS half, branch `feat/aqua-poo-1071-scaffold`: `src/lib/aqua/` module skeleton (`server-only`), Drizzle pointed at `AQUA_DATABASE_URL` (already in `.env.local`), migrations for `aqua_ships` + `aqua_fills` only, address config mirroring VERIFIED.md. Keep it SMALL.
4. POO-1061 compiler in `src/lib/aqua/api/compiler/` per PRG rules v2 (canonical order WITHOUT the tokenIn fee opcode; both-tokens ship; band below spot; salt-must-change invariant WITH a test; output = ABI-encoded Order bytes + ship CallInfo, PRG-R9/R10). CLI wrappers `ship`/`roll`/`dock`. Hand the two launch ship payloads (production band spot-15%..-5%, demo band spot-0.3%..-0.1%, sized within the 10% sleeve combined) to Track A/Murilo for S2.
5. After launch, in `pool-party-aqua`: POO-1066 taker (`scripts/taker.ts`): reconstruct the live Order from the on-chain `Shipped` event data (public data availability; keeps the public repo self-contained), dry-run `quote()`, then real fills at small clips against the demo band; at least one fill LARGER than the hot buffer to force the JIT trace; append every tx to `docs/FILLS.md`; label everything self-directed settlement proofs.
6. POO-1065 status (`scripts/status.ts`): `rawBalances` + `parkedBalance` + wallet balances + event history -> NAV + carry-vs-fills attribution printout. This is the demo's numbers screen.
7. POO-1067 only if everything above is green: one read-only-first page on the frontend branch (vault state, sleeves, band vs spot, fills with Arbiscan links), deposit/redeem buttons second.

## Sync points

| When | Gate | Who |
|---|---|---|
| **S1 ~T+3** | Rehearsal green + fee-variant verdict (B). Vault skeleton compiling, interface locked (A). If the tokenOut fee exists, Murilo rules on re-adding the protocol fee to the program NOW (one line in the compiler) | A + B + Murilo |
| **T+6 checkpoint** | Vault tests not closing -> cut test depth further (keep inflation + owner gating + JIT), never slip the launch | A |
| **S2 ~T+8..12** | **LAUNCH**: deploy + verify + seed $50-200 + two ships. Murilo signs everything. Smoke test: `quote()` at 3 sizes + `rawBalances` match compiler expectations | A drives, B provides payloads, Murilo signs |
| **S3 right after** | First fills incl. the JIT money-shot trace. RECORD THE TRACE IMMEDIATELY (screen capture), do not wait for T+17 | B fills, A captures |
| **T+17..20** | `RUNBOOK.md`, README continuity check, secret scan (gitleaks), demo dry-run, submission checklist (POO-1070) | both + Murilo |

## Murilo's own checklist (not a track)

- Hold the manager key; sign: deploys, seed, ships, rolls.
- Rule calls when pinged: fee tokenOut verdict at S1; any frozen-interface change; cut decisions at checkpoints.
- Final demo recording + submission.
