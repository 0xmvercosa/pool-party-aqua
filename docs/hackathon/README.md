# Active Reserve: judge package

**Active Reserve** is a managed on-chain strategy where the capital backing a resting bid keeps
earning until the block it is spent. Investor USDC sits in a vault, about 95 percent of it supplied
to Aave v3; the vault ships a SwapVM program to the official 1inch Aqua registry quoting a buy band
below spot. Aqua quotes that band off virtual balances, so the whole sleeve is quotable while the
money is still in Aave. When a taker fills, the router calls the vault's `preTransferOut` hook before
it moves anything, the vault withdraws exactly the shortfall from Aave, and the swap settles. One
transaction contains the Aave withdrawal and both legs of the swap. It is live on Arbitrum mainnet
and it has settled five real fills: three buy-side into the band, every one served by a
just-in-time Aave withdrawal, plus two reverse fills that closed the position out.

| | |
|---|---|
| Network | Arbitrum One (chain id 42161) |
| PartyVault | [`0xec870a6A9E8EE41B349FD0766b8f295D6EDC6610`](https://arbiscan.io/address/0xec870a6A9E8EE41B349FD0766b8f295D6EDC6610) (source verified) |
| AaveV3Adapter | [`0x6d409fF8578D017AddDB2e9Ad0848D8F0A65aBAe`](https://arbiscan.io/address/0x6d409fF8578D017AddDB2e9Ad0848D8F0A65aBAe) (source verified) |
| Program (PRG-R1 v3, measured) | `[deadline][concentrateGrowLiquidity2D][flatFeeAmountInXD 80bps][xycSwapXD][salt]` |
| Mainnet fills | 5: 3 buy-side into the band, all three on the just-in-time path, plus 2 reverse fills at close-out ([FILLS.md](../FILLS.md)) |
| Tests | 62 Foundry green (38 vault unit, 6 differential against OpenZeppelin ERC-4626, 13 adapter fork, 5 launch fork), plus `tsc --noEmit` and vitest on the band math |
| 1inch contracts | official Aqua registry `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a` and AquaSwapVMRouter `0x1111113Db0e0ef9D0E3A50d5f094a3a57a26C0DE`, both used unmodified |
| Size | 10 USDC seed under a 200 USDC `maxTvl`, the manager's own capital |

---

## Start here

If you have 10 minutes, read [01_WHAT_WE_BUILT.md](./01_WHAT_WE_BUILT.md), then the money shot below,
then run the two commands in the verification block that need no money.

| File | Why open it |
|---|---|
| [01_WHAT_WE_BUILT.md](./01_WHAT_WE_BUILT.md) | The product and the mechanism, and why a normal AMM cannot do this |
| [02_ARCHITECTURE.md](./02_ARCHITECTURE.md) | As-built contracts, flows, custody boundary, diagrams |
| [03_INTEGRATIONS.md](./03_INTEGRATIONS.md) | Every external system, pinned versions, addresses, exact calls |
| [04_QUALIFICATION.md](./04_QUALIFICATION.md) | Hackathon requirements mapped to live on-chain evidence |
| [05_REFERENCES.md](./05_REFERENCES.md) | Reference links, dependencies, attribution, licensing |
| [06_ROADMAP.md](./06_ROADMAP.md) | What is designed but not shipped, and what comes next |
| [07_PROCESS.md](./07_PROCESS.md) | How it was built: rules discipline, measurement, review, merge train |
| [08_COMMIT_HISTORY.md](./08_COMMIT_HISTORY.md) | Every commit explained, and how to read a squash-merged history |
| [../VERIFIED.md](../VERIFIED.md) | Measured ground truth: which Aqua generation is live, the opcode table, the maker-hook signature, the seven traps |
| [../05_DEMO_WALKTHROUGH.md](../05_DEMO_WALKTHROUGH.md) | Every command from empty machine to live fills, about 15 minutes and 0.30 USD of gas |
| [../FILLS.md](../FILLS.md) | The settlement ledger, with fill 1 decoded log by log |
| [../01_BUSINESS_RULES.md](../01_BUSINESS_RULES.md) | The numbered, versioned rules every contract and script implements |
| [../../RUNBOOK.md](../../RUNBOOK.md) | Operations: deploy, seed, ship, roll, emergency stop, key handling, the launch record |

Planning artifacts ([../00_ARCHITECTURE_AND_PLAN.md](../00_ARCHITECTURE_AND_PLAN.md),
[../02_WORKPLAN.md](../02_WORKPLAN.md), [../03_EXECUTION_PLAN.md](../03_EXECUTION_PLAN.md),
[../04_KICKOFF_2TRACKS.md](../04_KICKOFF_2TRACKS.md)) were written before and during the build. Treat
them as process evidence. Where they disagree with the code or with `VERIFIED.md`, the code and
`VERIFIED.md` win.

---

## The money shot

One transaction: an Aave withdrawal, the maker paying the taker, and the taker's ETH landing in the
vault.

**[`0xbc64ec2db39c6a8f718487268e4195c63e472f0ad0ae1f46e09919a1a9c5bb83`](https://arbiscan.io/tx/0xbc64ec2db39c6a8f718487268e4195c63e472f0ad0ae1f46e09919a1a9c5bb83)**
Arbitrum block 487666888, 336,000 gas. 0.0003 WETH in, 0.556382 USDC out, implied 1854.61 USD per ETH.

| Log | Contract | Event | Meaning |
|---|---|---|---|
| 1 | aUSDC | `Transfer` to `0x0` (burn) 56,379 | the Aave position is being withdrawn |
| 3 | USDC | `Transfer` aToken to vault 56,382 | the withdrawn USDC arrives at the vault |
| 4 | Aave Pool | `Withdraw` | Aave's own record of the same withdrawal |
| 5 | PartyVault | `JitUnparked` | the vault's record: it covered a shortfall mid-settlement |
| 6 | USDC | `Transfer` vault to taker 556,382 | the maker pays the taker |
| 7 | Aqua | `Pulled` | Aqua's accounting of that payment |
| 8 | WETH | `Transfer` taker to router 3e14 | the taker's 0.0003 WETH goes in |
| 11 | WETH | `Transfer` router to vault 3e14 | the ETH lands in the vault |
| 13 | Aqua | `Pushed` | Aqua credits the WETH side that shipped at amount 0 |
| 14 | AquaSwapVMRouter | `Swapped` | the swap itself |

Read logs 1 and 6 together. The vault owed 556,382 USDC and its wallet held 500,000. It withdrew
exactly 56,382 from Aave, the shortfall and not a unit more. Every one of those units was earning
interest until that transaction executed. The 3-unit gap between the aToken burn and the USDC
received is Aave scaled-balance rounding.

---

## Verify it yourself, without spending anything

```bash
# 1. Get the code (submodules are OpenZeppelin contracts and forge-std)
git clone https://github.com/0xmvercosa/pool-party-aqua.git && cd pool-party-aqua
git submodule update --init --recursive && pnpm install
```

```bash
# 2. Run the whole suite, including the Arbitrum fork suites
cd contracts && forge test && cd ..
```

Proves: 62 tests green. The fork suites hit live Arbitrum through a public endpoint, re-verify every
address in `AddressBook.sol` against the chain, and rehearse the launch sequence (seed, park, ship
both bands, read the virtual balances back, dock, revoke, redeem) against the **real** Aqua registry.

```bash
# 3. Read-only against mainnet: no fork, no transaction, no key
pnpm verify:onchain
```

Proves: which Aqua generation is actually live (there are two on Arbitrum, and the upstream READMEs
document the dead one), the measured opcode table, and that our program builder round-trips all four
pre-existing live gen-2 programs to byte-identical bytes. Defaults to the public RPC, so no
configuration is required.

```bash
# 4. Read the settlement ledger and the decoded JIT trace
cat docs/FILLS.md
```

Proves: the three mainnet fills, each with its transaction hash, size, implied price and band, plus
fill 1 decoded log by log. Open any hash on Arbiscan and check the log list against the table above.

```bash
# 5. Optional, needs anvil: the fork rehearsals and the seven traps
pnpm fork:all
```

Proves: the full loop plus the guardrails, each demonstrated as a real on-chain failure. Trap A is
the maker hook firing strictly before the pull, with a fill 8.6x larger than the hot buffer settling
in one transaction. Do not leave a fork running between sessions; the `fork:` scripts start a fresh
one and tear it down.

---

## Scope honesty

**Shipped:** the vault (ERC-4626 conversion math with a +3 decimals offset, manager seeds first,
internal non-transferable share ledger, USDC-only redemption, single-owner `execShip`/`execDock`, the
JIT settlement hook, `maxTvl`, `dockAll`), the Aave v3 carry adapter, the program compiler in the
measured canonical order, the taker and status scripts, the deploy and ops scripts, and the docs.

**Consciously cut from the 20-hour window:** PartyRouter with the OraclePriceAdjuster instruction
wired (the modified-SwapVM axis, designed and specified but not deployed), the keeper loop, the
manager UI, the in-vault Chainlink staleness gate, the redemption lockup, a separate KEEPER role, the
high-water-mark performance fee, `maxPerShip` and token allowlists, and main-app integration behind
the `aquaStrategies` flag. Each has a numbered rule and a stated in-window substitute in
[06_ROADMAP.md](./06_ROADMAP.md).

**The fills are self-directed settlement proofs** from our own taker wallet against our own strategy.
They are not arbitrage profit and not organic demand. A band bidding below spot cannot win arbitrage
by construction; it becomes the best bid only when the market falls into it. The external, real yield
in a window this short is the Aave carry, which accrues every block whether anyone fills or not.

---

## Licensing and attribution

Our code is MIT ([../../LICENSE](../../LICENSE)). 1inch Aqua and SwapVM are source-available under
Degensoft licenses, not OSI open source; non-commercial use including hackathons is explicitly free.
No upstream source is vendored here: our contracts restate only the ABI shapes they call and cite the
upstream tag. Attribution, quoted verbatim as the license requires: "Aqua — © Degensoft Ltd 2025".
Full detail in [05_REFERENCES.md](./05_REFERENCES.md).

## Why the fill price sits below the quoted band

Fill 1 settled at an implied 1854.61 USD per ETH while the demo band reads 1867.56 to 1871.30.
Both numbers are correct: the band is the curve, and the program also charges an 80 bps maker
premium (`flatFeeAmountInXD`) before the curve executes. The taker therefore pays band price
minus the fee we charge, which is exactly the spread the strategy earns. Fill 3 shows the same
relationship on the production band.
