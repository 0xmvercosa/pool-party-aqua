# Process: how this was built

A 20-hour window, two parallel tracks, one mainnet launch. This file is the evidence that the
result was engineered rather than improvised: what we read before writing anything, how rules
gated implementation, the specific places where the plan was wrong and the chain corrected it,
what independent review caught before merge, and what broke live.

Everything here is checkable in this repository. Commit hashes are on `main` unless marked
otherwise; timestamps are the commit clock (UTC+1) as recorded by git. For the product itself see
[01_WHAT_WE_BUILT.md](./01_WHAT_WE_BUILT.md); for what is deferred and what comes next see
[06_ROADMAP.md](./06_ROADMAP.md).

---

## 1. Research first, then a plan, then code

Before a line of Solidity existed, the upstream ground was read in full: the Aqua and SwapVM
whitepapers, and the `1inch/aqua`, `1inch/swap-vm` and `1inch/sdks` repositories at source level,
in parallel by an agent swarm, plus a read-only sweep of the Pool Party frontend for integration
fit. The method is recorded in the header of
[00_ARCHITECTURE_AND_PLAN.md](../00_ARCHITECTURE_AND_PLAN.md).

Nine candidate products came out of that pass and were judged adversarially against contract
source rather than against the whitepapers. Most died on contact with the **deployed** opcode
subset: limit orders, TWAP, Dutch auction and invalidators are full-SwapVM features that revert on
today's Aqua deployments, so a design that needed them was not a design. Two composition traps
killed most of the rest: curve ordering inside a program, and the rule that a one-sided strategy
must still register both tokens.

The winner was chosen for **feasibility and fit, not novelty alone**, and it is worth saying
plainly. Active Reserve needed one small new contract, used only opcodes that are live on the
official router, mapped 1:1 onto a product Pool Party already knows how to sell (a managed
strategy with pooled investor capital), and its differentiator was a fact confirmed in source
before we relied on it: the `preTransferOut` maker hook fires before `AQUA.pull`, so lending
capital can be withdrawn inside a fill.

The first commit in this repository, `e37ddad` at 13:34, is that research written up as an
architecture ([00_ARCHITECTURE_AND_PLAN.md](../00_ARCHITECTURE_AND_PLAN.md)), a rule set and a
workplan. Code starts three hours later.

---

## 2. Rules gate implementation

Pool Party's house rule is that nothing gets implemented without numbered, testable, versioned
business rules. [01_BUSINESS_RULES.md](../01_BUSINESS_RULES.md) is the single source of truth, with
one prefix per component: VLT (vault), ADP (carry adapter), PRG (program compiler), KPR (keepers),
BOT (taker), IDX (indexer/NAV), SRV (server module), RTR (PartyRouter), FE (frontend). Every
Linear issue embeds its own subset verbatim; where an issue and the document disagree, the
document wins and the issue is re-synced.

Rules carry versions and the versions moved during the build, in public: SRV to v3 when the
backend decision changed, PRG-R1 v1 to v3 when the program order was measured, PRG-R7 to v3 when
its evidence clause turned out to be false, VLT-R9 to v2 when the hook signature was measured. The
window cuts are recorded the same way, as an explicit annotation inside the VLT block naming what
is in scope and what is deferred, rather than as silence.

**Frozen interfaces made the parallelism possible.** Six things were declared unchangeable without
an epic comment and Murilo's acknowledgement ([04_KICKOFF_2TRACKS.md](../04_KICKOFF_2TRACKS.md)):
`ICarryAdapter{park,unpark,parkedBalance}`, the vault external surface including the 9-argument
`preTransferOut`, the mandate shape, the canonical program order, the `compile()` return shape,
and the database table names. That is what let Track A write a vault that answers a hook while
Track B wrote the compiler that produces the bytes that trigger it, with neither waiting for the
other and neither guessing. When the program order had to change, it changed through the protocol:
measured, proposed, acknowledged by Murilo when he authorised the merge train, then written back
into the rules and every downstream document in one commit (`79f78c5`).

---

## 3. Measurement over assumption

This is the section that matters most. In five places the plan was confidently wrong and the chain
corrected it. All five were caught before they could cost money, and all five are recorded in
[VERIFIED.md](../VERIFIED.md) with reproduction commands.

| # | What the plan said | What the chain said | How we found out |
|---|---|---|---|
| 1 | "Address discrepancy to resolve": four addresses across two READMEs and the SDK | No discrepancy. Two complete parallel generations, and the READMEs document the **dead** one | Read both registries and both routers on chain, including each router's `AQUA()` getter |
| 2 | A pre-seeded opcode table | Off by one across the board. Opcode equals the index in the SDK's `aquaInstructions` array | Decoded all four pre-existing gen-2 ships and re-built them to byte-identical bytes |
| 3 | Curves are terminal, fee before `concentrate` | `concentrate` shapes reserves, `xycSwapXD` executes, the flat fee sits between them, `salt` sits after | Decoded the live programs, then ran the old order on a fork and watched it revert |
| 4 | The protocol fee opcode is avoided by live makers | All four live programs **use** it. They can afford it because they fund both sides | Decoded the fee opcode and its arguments out of every live program |
| 5 | Hook is `onPreTransferOut(token, amount)` | 9 arguments, selector `0x5a394f80` | Captured the raw calldata the deployed router sends to a maker contract on a fork |

**1. Two generations, not one discrepancy.** The plan listed the address confusion as a day-0 risk
to "resolve on Arbiscan". What was actually deployed is two complete, parallel generations: gen 1
with 43 ships and 579 pulls, last active around 2026-04, and gen 2 with 4 ships and 14 pulls, last
active 2026-07-24. `@1inch/swap-vm-sdk@0.3.0` references only gen 2; the upstream READMEs document
gen 1. Building against the READMEs would have produced a technically working demo against a dead
registry.

**2. The opcode table was off by one.** The table pre-seeded into VERIFIED.md by the plan review
was wrong for every entry. The measured truth is stronger than a corrected table: the SDK's
`instructions.aquaInstructions` array mirrors the deployed array exactly, so the SDK builder is
the table. The proof is not an argument, it is a round trip. All four live ships decode through
`AquaProgramBuilder.decode()` and re-`build()` to byte-identical program bytes; a table off by one
would have thrown or produced garbage arguments on the first instruction. The same pass pinned the
upstream tag: the live router runs the pre-`OpcodeList` array dispatch and matches **no public
tag**, so the reading instruction is `swap-vm@v1.0.1`, never `main`.

**3. `concentrate` is not the terminal curve.** Both the architecture doc and PRG-R1 v1/v2 said
curve instructions are terminal and put the flat fee before `concentrateGrowLiquidity2D`. Every
live program says otherwise: `concentrate` shapes the reserves and `xycSwapXD` executes the swap on
them, with the flat fee between the two and `salt` after the curve. The fork proved the
consequences (traps C in the [VERIFIED.md](../VERIFIED.md) trap table): the old order verbatim,
having no executing curve, reverts `TakerTraitsAmountOutMustBeGreaterThanZero`, and a fee emitted
after the executing curve reverts `0x77e79f46` at quote time. Upstream documents a post-curve fee
as "silently never applied". On the deployed router it is better than that: the strategy becomes
unquotable, so a mis-ordered program can never reach a fill and silently forgo the premium.

**4. The right rule for the wrong reason.** PRG-R7 v2 kept the on-chain protocol fee opcode out of
v1, and justified it partly with "confirmed by all four live programs avoiding it". That clause was
simply false: all four use `aquaProtocolFeeAmountInXD`. The conclusion survived for a different
reason, which the measurement supplied: those makers ship both sides with non-zero amounts, so the
tokenIn pull always has balance, while our buy band ships WETH at 0 and reverts with an arithmetic
underflow (trap E). We rewrote the evidence anyway, in v3, with the correction stated out loud in
VERIFIED.md. A rule whose conclusion is right and whose reasoning is wrong is a trap for whoever
edits it next.

**5. The hook signature nobody publishes.** The published SwapVM ABI does not document the maker
hook, and the kickoff briefing froze a two-argument sketch, `onPreTransferOut(token, amount)`. The
rehearsal pointed the deployed router at a stub maker on a fork and captured the raw calldata: nine
arguments, selector `0x5a394f80`, carrying the settled `amountOut` so exact-amount JIT is possible.
A vault implementing the frozen sketch would have compiled, deployed, verified, and then never been
called: the router would have called a function it does not have, and every fill larger than the hot
buffer would have failed at launch, in front of judges, with real money already seeded. VERIFIED.md
carries that finding under a heading that says ACTION REQUIRED FOR TRACK A, and VLT-R9 went to v2
before the vault was written.

Two smaller measurements are worth naming because the product rests on them: `safeBalances` never
reads the maker's wallet balance, so a small hot buffer can quote the whole sleeve (the 90/10
premise survives contact with source), and a docked strategy hash is dead forever behind a
sentinel, which is why every roll must change the salt (trap G, `StrategiesMustBeImmutable`).

Seven traps in total were demonstrated on chain rather than reasoned about, each a failing input
we watched break with the revert identified where the ABI allowed it. Each one became a compiler
guardrail. Reproduce the read-only half with `pnpm verify:onchain` and the fork half with
`pnpm fork:traps`.

---

## 4. Independent review before anything irreversible

Three review passes, each before a point of no return, each with findings verified adversarially
rather than accepted on assertion.

**Pass 1, the plan, before implementation.** A source-level and on-chain review of the architecture
and rules. Its rulings landed as `d1decc3` at 16:06: use the gen-2 addresses, pin
`swap-vm@v1.0.1`, take the tokenIn fee opcode out of the v1 program, cut the vault to a demo
minimum for the window, create VERIFIED.md as a separate ground-truth artifact, license our code
MIT, and document continuity for the judges. Honesty about that review: its pre-seeded opcode table
was itself wrong, and the measurement pass corrected it two hours later. A review is an input, not
an authority; that is exactly why the measurement ran anyway.

**Pass 2, five stacked PRs, before the merge train.** PRs #1 (vault, POO-1059), #6 (adapter,
POO-1060), #4 (launch scripts and runbook, POO-1062 prep), #3 (ground truth and traps, POO-1058)
and #5 (taker and status, POO-1066 and POO-1065) were reviewed as a stack and merged between 18:36
and 18:41 once the findings were closed.

| Finding | Why it was severe | Fix |
|---|---|---|
| The taker sent fills with no on-chain bound | A quote is not a promise. A market that moved between quote and inclusion would have filled at whatever the curve then said | `6f3acd9`: TakerTraits threshold set to quote minus `--slippage-bps` (default 50), so a moved market reverts |
| The taker executed by default | One mistyped command on mainnet, with real money, under demo pressure | `6f3acd9`: dry-run is the default, nothing is sent without an explicit `--execute` |
| No daily volume cap (BOT-R3 unimplemented) | The per-fill cap alone does not bound a loop | `6f3acd9`: mainnet fills summed from `docs/FILLS.md` itself and refused past 3 WETH per day |
| `status.ts` described a carry number it did not compute | An accounting screen that asserts rather than derives is worse than no screen | `6f3acd9`: net principal parked reconstructed from the USDC transfer legs, NAV cross-checked against `vault.totalAssets()` on chain |
| Evidence script with a decaying window | `verify:onchain` scanned head minus 3M blocks, so the reference-ship check would start failing for anyone reproducing after 2026-07-29 | `4443a62`: scan floored at `GEN2_FIRST_ACTIVITY_BLOCK` |
| Fork fills logged as if they were mainnet | One mislabelled row would undermine the whole submission artifact | `6f3acd9`: fork fills go to `FILLS_FORK.md`, whose header no longer claims mainnet |
| `band.ts` claimed tests it did not have | A header that lies about coverage | `4443a62`: 5 exact-arithmetic pins on the decimals conversion and band math |

**Pass 3, the runbook, before the launch.** Three gaps, all real, closed in `e26c263` and reflected
in [RUNBOOK.md](../../RUNBOOK.md): the smoke test printed one allowance line while the runbook told the
operator to check four, so it now prints all four plus a warning if the router holds an allowance
it never needs; rolling a band said "after an `execDock`" with no command, so a `DockBand` op was
added that refuses a hash the vault does not have active; and `Deploy.s.sol`'s assertions run
inside forge's simulation, proving what the script intended to publish rather than what a node now
serves, so a read-only `VerifyDeployment` gate was added that reads every immutable back off live
state, including the adapter-to-vault binding that a simulation cannot establish. The commit
message states the principle it was built on: a launch gate that can only be run by setting
environment variables is a gate nobody tests, so the checks take explicit arguments and the fork
suite exercises all four rejection paths.

**Plus the scan the checklist called for.** `pnpm scan:secrets` (`b56b189`, merged into main)
scans every git object rather than the working tree, because a credential that was committed and
later deleted still ships with the history. It runs a self-test on every invocation that plants six
known-fake secrets, deletes them, commits again, and requires all six to still be detected, so a
clean result means the scanner was demonstrated to work moments earlier instead of merely staying
quiet. Result: no findings, with two allowlisted literals, both Anvil's published dev keys.

---

## 5. Two tracks, frozen interfaces, one PR per issue

Staffing was two working tracks plus Murilo as manager-key holder and approver, not a track.
Track A owned contracts (POO-1059 vault, POO-1060 adapter, co-owned the launch). Track B owned the
TypeScript rails (POO-1058 ground truth, scaffolds, POO-1061 compiler, POO-1066 taker, POO-1065
status). The coupling between them was the frozen interface list of section 2 and nothing else.

The working rules were deliberately boring: one session, one issue, one branch, one PR,
squash-merged; commit and push after every green step, because continuous timestamps are part of
the submission and backdating is not an option; a checkpoint on the epic every three hours; and a
gate rule that any red item on the critical path pulls both tracks onto it. Mainnet discipline was
absolute: nothing touched mainnet before POO-1058 was Done, only the manager key deployed, seeded
and shipped, and the taker ran from a separate wallet holding only its own working capital
(BOT-R4, and the taker wallet `0x67Fd51e5082205AF0bD97039a6124Ff3368aD0da` is visibly not the
manager `0xc365B6795443380eb76516dA0Cedd5a00B349d66` on chain).

What that produced, countable with `git log`: 29 commits on `main`, 54 across all branches
including the five merged PR branches, all inside the window.

---

## 6. Timeline

| Phase | Commit clock | Evidence |
|---|---|---|
| Research (whitepapers, both repos, 9 judged candidates) | before 13:34 | method block in [00_ARCHITECTURE_AND_PLAN.md](../00_ARCHITECTURE_AND_PLAN.md) |
| Plan, rules v1, workplan, product name, execution plan, 20h compression | 13:34 to 14:55 | `e37ddad`, `1f0487f`, `b015ca6`, `66ef043`, `9c0bf41`, `bc0d36d`, `a7144bc` |
| Independent plan review, rulings incorporated | 16:06 | `d1decc3` |
| Two-track kickoff briefing | 16:21 | `3277205` |
| Track B: workspace, on-chain verifier, fork rehearsal, seven traps, measured hook | 16:40 to 17:00 | `d98fd4f`, `1fc7fc9`, `08f9b3f`, `1c8ab4d`, `eab2ff9` |
| Track A: adapter and Arbitrum fork suite (vault in flight in PR #1) | 16:58 to 17:25 | `5258e7c`, `51a647b`, `8231317` |
| Launch scripts, runbook, full launch rehearsal on fork; taker and status green | 17:06 to 17:55 | `18fc39d`, `c494971`, `3a27086` |
| Review fixes on the stack | 18:29 to 18:36 | `4443a62`, `6f3acd9` |
| Merge train, five PRs | 18:36 to 18:41 | `90ce37e` (#1), `12e5408` (#6), `dc31b0e` (#4), `9cc278d` (#3), `34e754f` (#5) |
| Rules re-synced to the measurement (PRG-R1 v3, PRG-R7 v3, VLT-R9 v2) | 18:45 | `79f78c5` |
| Launch prep: runbook gaps, clean-checkout fork gate, secret scan, launch payloads | 19:02 to 20:07 | `e26c263`, `069c179`, `b56b189`, `340e620` |
| **Mainnet**: deploy, verify, seed, park, ship both bands | 20:12 to 20:33 | `8586b2d`, `dde5a93`, `4157404`, `175ed7b`, [RUNBOOK section 10](../../RUNBOOK.md) |
| **Three live fills**, including the decoded JIT trace | 19:34 to 19:43 UTC | [FILLS.md](../FILLS.md), `5e70e35`, `f122223` |
| Accounting correction on the live numbers | 20:46 | `87bc783` |
| Wind-down: reverse fills, emergency stop, cap to 0, seed redeemed | after the demo | `8a133fe`, `6ad76d9`, [RUNBOOK section 11](../../RUNBOOK.md) |
| Judge package: full reproduction walkthrough | 00:51 next day | `9c3ccfd` |

The declared window was 20 hours (decision D7). The public history spans 13:34 on 2026-07-25 to
00:51 on 2026-07-26, with the mainnet deployment at 20:21, six hours and 47 minutes after the first
commit. The app side ran in parallel on a branch of the private product repository across the same
hours (server module and compiler at 19:10, read-only investor page at 19:25, hook fix at 20:31).

Read the fills row with the framing that appears everywhere else in this package: those settlements
are self-directed settlement proofs from our own taker, not arbitrage profit and not organic
demand. The external real yield in the window is the Aave carry.

---

## 7. What went wrong live, and what we did about it

Seven failures happened after the code was green, six of them with real money already committed.
None was papered over; each landed as a commit whose message states the failure, which is why the
[walkthrough](../05_DEMO_WALKTHROUGH.md) now works from a cold clone.

| Symptom | Cause | Fix |
|---|---|---|
| `forge script` failed at launch time | The runbook ran the commands from the repository root, where there is no `foundry.toml`, so forge compiled with empty remappings and fell over on the OpenZeppelin submodule's own tests | `8586b2d`: every command runs from `contracts/`, verified green in simulation |
| Deploy aborted before broadcasting | The address-prediction guard computed against Foundry's default sender instead of the broadcaster | `dde5a93`: `--sender` added to every broadcast command. The guard worked exactly as designed: it aborted at zero spend rather than publishing a mis-wired adapter and vault |
| `--verify` failed | Arbiscan's V1 per-chain endpoint is deprecated | `4157404`: `foundry.toml` points at the Etherscan V2 endpoint, and the curl fallback documents the `+` to `%2B` encoding gotcha in `compilerversion`. Both contracts read as verified |
| A fill reverted with an arithmetic underflow | The demo band ran out of depth | Nothing to fix. That is Aqua's no-bad-debt design observed live: `pull` reverts rather than over-committing. Documented in [05_DEMO_WALKTHROUGH.md](../05_DEMO_WALKTHROUGH.md) under what will happen and what it means |
| The reverse fill at close-out reverted with no reason string | `_ensureAquaAllowance` only tops up what a ship commits, and a buy band ships WETH at amount 0, so the vault had no WETH allowance to Aqua at all | `6ad76d9`: [RUNBOOK section 7b](../../RUNBOOK.md) grants WETH explicitly and states the ordering rule, since the emergency stop revokes the only route the inventory has out |
| Live carry read negative | Aave delivers withdrawals straight from the aToken contract, so JIT unpark volume was counted as principal outflow, exactly matching the JIT sum at -0.1286 | `87bc783`: both senders watched. Carry then read +0.000007 USDC an hour into a 10 USDC seed, with NAV still cross-checking against `totalAssets()` at diff 0 |
| The app-side compiler omitted the `preTransferOut` hook | Two compilers existed, this repo's launch script and the app module, and only one carried the measured hook detail | Fixed on the app branch (private repo, `3c5d630a`, "killing the JIT path"). The launch payloads were built by [`scripts/build-orders.ts`](../../scripts/build-orders.ts), which carries the hook on a zero-address `Interaction` with non-empty data, so mainnet was never exposed |

Three things we would change next time, stated because they are the honest read of the above. The
hook signature was measured **after** the frozen-interface list was published, so a briefing went
out with a wrong vault surface in it; measurement should precede interface freezing, not follow it.
The vault shipped at 521 lines against a "roughly 200 lines, boring on purpose" target, which is
worth watching before an audit is scoped. And two compilers for the same bytes is one too many:
the divergence was caught by a human reading a commit, not by a test, and the only structural fix
is one compiler with two callers.
