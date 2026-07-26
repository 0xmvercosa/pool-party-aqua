# Commit history, explained

"Use version control. Submissions with large single commits or missing histories may be
disqualified." This file exists because that is a judging criterion, and because the history is
itself the clearest evidence of how the project was actually built.

## How to read this repository's history

**`main` is linear and squash-merged.** Every feature landed through a pull request, and each PR
became exactly one commit on `main` whose subject carries the PR number and the tracking issue,
for example `feat(aqua): PartyVault demo-minimum + Foundry workspace [POO-1059] (#1)`.

**The granular work lives in the pull requests.** GitHub keeps every branch commit, so a reviewer
who wants the fine grain opens the PR and reads its commits: the vault PR alone carries seven,
the ground-truth PR eight. Nothing was flattened away or rewritten to look tidy.

**Everything was pushed continuously.** Push timestamps, which GitHub records separately from
commit timestamps, run from 13:34 to 00:51 on 2026-07-25. Nothing was backdated, and no commit
was authored after the fact to fill a gap.

**Convention.** `<type>(aqua): <subject>` with types `feat`, `fix`, `docs`, `chore`, `test`,
`style`. Subjects state the outcome, and bodies explain the reasoning, especially where a
measurement contradicted the plan.

## The five pull requests

| PR | Branch | Issue | What landed | Branch commits |
|---|---|---|---|---|
| [#1](https://github.com/0xmvercosa/pool-party-aqua/pull/1) | `feat/aqua-poo-1059-partyvault` | POO-1059 | Foundry workspace, frozen interfaces, PartyVault, 38 unit tests, the OpenZeppelin differential suite, published ABIs | 7 |
| [#6](https://github.com/0xmvercosa/pool-party-aqua/pull/6) | `feat/aqua-poo-1060-aave-adapter` | POO-1060 | AaveV3Adapter and its Arbitrum fork suite, JIT overhead measured at 26k gas | 3 |
| [#4](https://github.com/0xmvercosa/pool-party-aqua/pull/4) | `chore/aqua-poo-1062-mainnet-launch` | POO-1062 | Deploy and Ops scripts, RUNBOOK, a full launch rehearsal against the real Aqua registry | 6 |
| [#3](https://github.com/0xmvercosa/pool-party-aqua/pull/3) | `chore/aqua-poo-1058-rehearsal` | POO-1058 | TypeScript workspace with pinned SDKs, the fork rehearsal, seven on-chain trap proofs, the measured `VERIFIED.md` | 8 |
| [#5](https://github.com/0xmvercosa/pool-party-aqua/pull/5) | `feat/aqua-poo-1066-taker` | POO-1066, POO-1065 | The taker and the status report, green end to end on a fork | 4 |

PR #2 was the adapter's original pull request. GitHub auto-closed it when its base branch was
deleted during the stacked merge, so #6 is its identical successor. The stack was merged bottom
up with a rebase after every squash, which is why `main` has no phantom diffs.

## The history, commit by commit

### Planning, before any code (13:34 to 16:21, ten commits)

The first ten commits contain no Solidity at all. That is deliberate: the architecture, the
numbered business rules and the decisions were written, reviewed and corrected first, and the
build then followed them.

| Commit | Time | Why it exists |
|---|---|---|
| `e37ddad` | 13:34 | The founding commit: architecture, business rules v1, workplan. 609 lines of decisions before a line of code, so the rules could gate the implementation rather than be reverse-engineered from it. |
| `1f0487f` | 13:42 | Records the decision that there is no separate backend: orchestration is a server module with an internal API layer, and the database mirrors the production model so a later migration is a module swap. |
| `b015ca6` | 13:52 | Resolves eight open decisions at once and fixes the two-repository structure. Rules bumped to v3 for the server section. |
| `66ef043` | 14:01 | Names the product Active Reserve and fixes the official 280-character description that the interface must use verbatim. |
| `b32e8a1` | 14:02 | A one-line README tightening. Small commits are not noise: they keep each change reviewable. |
| `9c0bf41` | 14:06 | The complete execution plan, every task cross-referenced to its tracking issue. |
| `bc0d36d` | 14:13 | The window collapsed to 20 hours, so the plan was rewritten as waves with explicit scope cuts instead of quietly slipping. |
| `a7144bc` | 14:55 | Adds the demo band and, with it, the honesty framing: our own taker generates the fills and the documentation says so everywhere. |
| `d1decc3` | 16:06 | The most consequential planning commit. An independent source-level and on-chain review found that the plan pointed at a dead Aqua generation, read the wrong upstream version, and specified a program that would revert on the first fill. This commit incorporates all of it, adds `VERIFIED.md`, the MIT license and the continuity note. |
| `3277205` | 16:21 | The two-track kickoff briefing that the parallel sessions worked from. |

### The build, merged as five pull requests (18:36 to 18:41)

The five squash commits land minutes apart because the branches were developed in parallel and
merged in a single ordered train, not because the work happened in five minutes. Each one is
large by design: it is an entire reviewed pull request.

| Commit | Time | What it is |
|---|---|---|
| `90ce37e` | 18:36 | PartyVault and the Foundry workspace, 2,993 lines. The vault is the Aqua maker: pooled deposits, a non-transferable internal share ledger using OpenZeppelin ERC-4626 math, the settlement hook, hard caps, and the emergency stop. |
| `12e5408` | 18:38 | AaveV3Adapter, 813 lines with its fork suite. Fifty lines of contract, the rest is proof: exact-amount withdrawals, vault-only access, and the just-in-time path exercised against live Aave. |
| `dc31b0e` | 18:39 | The launch tooling and the runbook, plus a fork rehearsal of the entire launch sequence against the real registry. Written before the launch so the live run had no improvisation. |
| `9cc278d` | 18:40 | The ground truth, 3,849 lines. The TypeScript workspace with exactly pinned SDKs, the fork rehearsal, and seven traps demonstrated on-chain rather than asserted in prose. This is where most of `VERIFIED.md` comes from. |
| `34e754f` | 18:41 | The taker and the status report, green end to end on a fork before either touched mainnet. |

### Correction and preparation (18:45 to 20:14)

| Commit | Time | Why it exists |
|---|---|---|
| `79f78c5` | 18:45 | Synchronises the rules to what the chain actually showed: the program order becomes v3 (`concentrate` shapes reserves, `xycSwapXD` executes, a fee after the executing curve reverts), the hook rule records the measured nine-argument signature, and a false piece of supporting evidence in an earlier rule is corrected rather than left standing. |
| `df8f503` | 18:51 | Splits the remaining work across the two tracks after the merge train. |
| `928b356` | 19:36 | The environment example is made to match the variables the launch actually needs. |
| `340e620` | 20:07 | `build-orders`, which emits the two launch payloads for the live vault using the same SDK calls the fork rehearsal already proved. |
| `8586b2d` | 20:12 | First live fix: the runbook told the operator to run `forge script` from the repository root, where there is no `foundry.toml`. Found by running it. |
| `dde5a93` | 20:14 | Second live fix: broadcast commands need `--sender`, otherwise the address-prediction guard simulates against the wrong nonce and aborts. The guard behaved exactly as designed and cost nothing. |

### Live on mainnet (20:21 to 21:02)

| Commit | Time | What happened |
|---|---|---|
| `4157404` | 20:21 | Both contracts deployed and verified on Arbitrum. The Arbiscan V1 endpoint had been deprecated that week, so verification went through the Etherscan V2 API and the configuration was updated for anyone who clones this. |
| `175ed7b` | 20:33 | The launch record: seed, park, and both bands shipped, with every transaction hash. |
| `5e70e35` | 20:37 | The first mainnet fill, with its transaction decoded log by log: the Aave withdrawal, the Aqua pull and the push back, in one transaction. |
| `f122223` | 20:44 | The fills counter was matching narrative table rows and numbering fills 12 and 13. Fixed by anchoring on the date cell, and the two rows relabelled. |
| `87bc783` | 20:46 | The carry attribution was reporting negative interest. Aave delivers withdrawals to the vault straight from the aToken contract, so just-in-time volume was being counted as principal leaving. With both senders watched, the live number is real interest, positive and growing. |
| `8a133fe` | 20:58 | The unwind script: the vault has no swap function by design, so selling accumulated inventory back through the band is the designed exit. |
| `6ad76d9` | 21:02 | The close-out procedure, including a trap found live: a buy band ships WETH at amount zero, so the vault never grants Aqua a WETH allowance, and selling inventory back needs one deliberate approval before the emergency stop revokes everything. |

### Documentation for review (00:51)

| Commit | Time | What it is |
|---|---|---|
| `9c3ccfd` | 00:51 | The full reproduction walkthrough: every command from an empty machine to three live fills and the numbers screen. |

## What the history shows

- **Documentation precedes implementation.** Ten planning commits, then code that follows the
  rules those commits fixed. The rules are numbered and versioned, and when one turned out to be
  wrong it was bumped in a commit that says why (`79f78c5`).
- **The chain corrected the plan, repeatedly, and the corrections are in the record.** The dead
  Aqua generation, the off-by-one opcode table, the program order, the fee direction, the hook
  signature: none of these were guessed right the first time, and each correction is a commit
  with its evidence.
- **Every live problem produced a fix commit.** Three of them (`8586b2d`, `dde5a93`, `6ad76d9`)
  exist only because someone ran the runbook against mainnet and it was wrong. That is the
  difference between a rehearsed procedure and a written one.
- **Bugs found by review were fixed before merge, not after.** A pre-merge review of the five
  stacked pull requests caught a swap with no slippage bound, a taker that executed by default,
  and an evidence script that would start failing days later. All three were fixed on their
  branches before the merge train ran.

## Verify it yourself

```bash
git clone https://github.com/0xmvercosa/pool-party-aqua.git && cd pool-party-aqua
```

```bash
git log --reverse --format='%h %ad %s' --date=format:'%H:%M'
```

```bash
git log --format='%h %s' --shortstat
```

Open any of the five pull requests to see the branch commits behind a squash, and compare their
push timestamps with the transaction timestamps on Arbiscan: the code was pushed before the
transactions it produced.

## The other repository

Part of this project lives in Pool Party's private product repository, on the branch
`feat/aqua-poo-1057-hackathon`: the server module and the strategy compiler that the wider
product will use, opened as pull request #664 there. It is out of scope for judging because it
cannot be made public, and everything needed to verify every claim in this submission is in this
repository. See the continuity section of the [root README](../../README.md).
