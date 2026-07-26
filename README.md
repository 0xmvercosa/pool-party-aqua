# Active Reserve: a lending-backed market maker on 1inch Aqua

A pooled vault that keeps about 95 percent of its USDC earning Aave v3 supply yield behind a
5 percent hot buffer, registers a sleeve worth about 10 percent of TVL with the official 1inch
Aqua registry as virtual balance, and quotes a buy-the-dip band below spot as a SwapVM program.
When a fill lands, a maker hook withdraws from Aave **inside the settlement transaction**, so the
parked capital is quotable liquidity the whole time.

> **Active Reserve.** An always-earning reserve that buys the dip. Capital earns Aave lending
> yield every block and is deployed automatically the instant the market dips into the manager's
> buy band, purchasing ETH below market price. Objective: accumulate ETH at a discount while
> never sitting idle.

Live on Arbitrum One, settling real fills. Built for the 1inch Aqua and SwapVM hackathon.

## Judges start here

**[docs/hackathon/](./docs/hackathon/README.md)** is the review package: what was built, the
as-built architecture, every integration, the requirement scorecard with transaction links, the
references, the roadmap, the process, and the commit history explained.

| | |
|---|---|
| Network | Arbitrum One (chainid 42161) |
| PartyVault | [`0xec870a6A9E8EE41B349FD0766b8f295D6EDC6610`](https://arbiscan.io/address/0xec870a6A9E8EE41B349FD0766b8f295D6EDC6610), source verified |
| AaveV3Adapter | [`0x6d409fF8578D017AddDB2e9Ad0848D8F0A65aBAe`](https://arbiscan.io/address/0x6d409fF8578D017AddDB2e9Ad0848D8F0A65aBAe), source verified |
| Mainnet fills | 5 (3 buy-side into the band, all three served by a just-in-time Aave withdrawal, plus 2 reverse fills at close-out) |
| Tests | 62 Foundry (unit, an OpenZeppelin ERC-4626 differential suite, and two Arbitrum fork suites) |
| Program | `[deadline][concentrateGrowLiquidity2D][flatFeeAmountInXD 80bps][xycSwapXD][salt]`, measured against the deployed router |
| Official contracts | Aqua registry `0x1111113CCf...a90a` and AquaSwapVMRouter `0x1111113Db0...C0DE`, both unmodified |

## The single transaction that is the whole product

[`0xbc64ec2db39c6a8f718487268e4195c63e472f0ad0ae1f46e09919a1a9c5bb83`](https://arbiscan.io/tx/0xbc64ec2db39c6a8f718487268e4195c63e472f0ad0ae1f46e09919a1a9c5bb83)

The taker sold 0.0003 WETH into the band. The vault owed 556,382 USDC and its wallet held
500,000, so inside that one transaction it burned aUSDC to withdraw exactly the 56,382 shortfall
from Aave, Aqua pulled the USDC to the taker, and the WETH was pushed back into the vault. Until
that instant, every one of those units was earning interest. The decoded log list is in
[docs/FILLS.md](./docs/FILLS.md).

## Verify it without spending anything

```bash
git clone https://github.com/0xmvercosa/pool-party-aqua.git && cd pool-party-aqua && git submodule update --init --recursive && pnpm install
```

```bash
forge test --root contracts
```

62 tests. The fork suites run against live Arbitrum through a public endpoint and re-verify every
address in `AddressBook.sol` against the chain, then rehearse the entire launch sequence against
the real Aqua registry.

```bash
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc pnpm verify:onchain
```

Read-only, no key, no money. It proves which Aqua generation is live, decodes the pre-existing
production programs and round-trips them through our builder to byte-identical bytes, shows the
opcode table we measured, and checks the maker shapes on the registry.

```bash
pnpm fork:all
```

Brings up its own throwaway Arbitrum fork and runs the full rehearsal, the seven trap proofs and
the taker, including the just-in-time path.

To reproduce the mainnet run end to end, follow
[docs/05_DEMO_WALKTHROUGH.md](./docs/05_DEMO_WALKTHROUGH.md).

## What lives where

| Path | What it is |
|---|---|
| `contracts/src/PartyVault.sol` | The Aqua maker: pooled USDC, a non-transferable internal share ledger with OpenZeppelin ERC-4626 math, ships and docks bands, answers the settlement hook |
| `contracts/src/AaveV3Adapter.sol` | The carry venue: supplies to Aave v3 and withdraws exact amounts, including from inside a fill |
| `contracts/src/AddressBook.sol` | Every canonical Arbitrum address with how it was verified |
| `contracts/script/` | `Deploy`, and the ops set: `SeedAndPark`, `ShipBand`, `DockBand`, `Smoke`, `VerifyDeployment`, `EmergencyStop` |
| `scripts/` | The TypeScript side: program compiler entry (`build-orders`), `taker`, `status`, `unwind`, the fork rehearsals, and `verify-onchain` |
| `docs/hackathon/` | The judge package |
| `docs/VERIFIED.md` | Measured ground truth: addresses, the opcode table, the maker hook, the traps |
| `RUNBOOK.md` | Operations: deploy, seed, ship, roll, close out, emergency stop, key handling |

The strategy compiler and the server module that the wider Pool Party product will use live in
the private product repository on the branch `feat/aqua-poo-1057-hackathon`. Everything needed to
verify every claim in this submission is in this public repository.

## What is deliberately not shipped

The window was 20 hours, so scope was cut on purpose and the cuts are listed rather than hidden.
Each one is designed and specified in [docs/01_BUSINESS_RULES.md](./docs/01_BUSINESS_RULES.md),
with the reasoning in [docs/hackathon/06_ROADMAP.md](./docs/hackathon/06_ROADMAP.md).

| Designed, not shipped | Rule | What runs instead |
|---|---|---|
| PartyRouter with `OraclePriceAdjuster` wired (the modified-SwapVM axis) | RTR | The manager watch plus `dockAll` is the price sentinel, stated as such in the runbook |
| In-vault Chainlink staleness gate | VLT-R4 | NAV values WETH at Chainlink and rejects a non-positive answer; the 90-minute bound is watched off chain |
| Redemption lockup | VLT-R6 | Lockup is 0 days for the event anyway |
| Separate keeper role and keeper loop | VLT-R7, KPR | One immutable owner; every operation is a deliberate manual action from the CLI |
| High-water-mark performance fee | VLT-R8 | Platform economics documented, not charged in-window |
| `maxPerShip` and token allowlists | VLT-R7, VLT-R10 | `maxTvl` plus a manager-only seed; the Aqua app is forced to the canonical router |
| Manager UI | POO-1068 | The CLI scripts are the manager surface |

Fills during the event were generated by our own taker and are labelled self-directed settlement
proofs everywhere they appear. A band that bids below spot cannot win arbitrage by construction:
it becomes the best bid only when the market falls into it. The external, real yield in the
window is the Aave carry, which accrues every block whether anyone fills or not.

## Licensing and attribution

1inch Aqua and SwapVM are source-available under Degensoft licenses, not OSI open source, and
non-commercial use including hackathons is explicitly free. No upstream source is vendored here:
our contracts restate only the ABI shapes they call and each cites the upstream tag it was
transcribed from (`aqua` v1.0.0, `swap-vm` v1.0.1). Our own code is MIT, see [LICENSE](./LICENSE).
Attribution, quoted verbatim as the upstream license requires: "Aqua — © Degensoft Ltd 2025".
Full detail in [docs/hackathon/05_REFERENCES.md](./docs/hackathon/05_REFERENCES.md).

No secrets and no production data are committed to this repository. `pnpm scan:secrets` runs a
reproducible scan with no install step.
