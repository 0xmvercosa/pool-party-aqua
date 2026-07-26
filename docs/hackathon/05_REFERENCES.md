# References, dependencies and attribution

Everything Active Reserve was built on, with links, pinned versions and the exact upstream files a
reviewer needs in order to check our claims rather than believe them.

Where a deep link into an upstream repository could not be confirmed, this page links the repository
or the tag tree and gives the in-repo path as a code span. That is deliberate: a wrong link is worse
than a path you have to click twice for.

---

## 1. 1inch Aqua and SwapVM

The core of the submission. Aqua is the shared-liquidity registry our vault ships to as a maker;
SwapVM is the virtual machine whose programs price our bands.

### Repositories and papers

| What | Where |
|---|---|
| Aqua | [github.com/1inch/aqua](https://github.com/1inch/aqua) |
| SwapVM | [github.com/1inch/swap-vm](https://github.com/1inch/swap-vm) |
| Aqua whitepaper | `docs/whitepaper-aqua-1.0.pdf` inside the Aqua repository |
| SwapVM whitepaper | `docs/whitepaper-swap-vm-1.0.pdf` inside the SwapVM repository |
| SDK monorepo | [github.com/1inch/sdks](https://github.com/1inch/sdks), packages under `typescript/aqua` and `typescript/swap-vm` |

### Read these at these tags, not at `main`

The live generation-2 router on Arbitrum does not run `main` and does not match any public tag
exactly. It runs the pre-`OpcodeList` array dispatch (v1.0.1 era), where the opcode byte is the array
index. Reading `main` will give you a different, banked opcode enum and you will conclude our
programs are wrong.

| Upstream | Tag | Tree |
|---|---|---|
| `1inch/aqua` | `v1.0.0` | [github.com/1inch/aqua/tree/v1.0.0](https://github.com/1inch/aqua/tree/v1.0.0) |
| `1inch/swap-vm` | `v1.0.1` | [github.com/1inch/swap-vm/tree/v1.0.1](https://github.com/1inch/swap-vm/tree/v1.0.1) |

Fetch them without cloning:

```bash
curl -sL -o aqua.tgz   https://codeload.github.com/1inch/aqua/tar.gz/refs/tags/v1.0.0
curl -sL -o swapvm.tgz https://codeload.github.com/1inch/swap-vm/tar.gz/refs/tags/v1.0.1
```

### The specific files a reviewer should open

| Upstream file | Why it matters to us | Our counterpart |
|---|---|---|
| `src/Aqua.sol` (`1inch/aqua` v1.0.0) | `ship` returns `keccak256(strategy)`; `dock` reverts `DockingShouldCloseAllTokens` unless the token list is complete; `pull` is a `safeTransferFrom` **from the maker**, so the maker approves the registry and never the router; a docked hash keeps a sentinel and is dead forever | [`contracts/src/PartyVault.sol`](../../contracts/src/PartyVault.sol) |
| `src/interfaces/IAqua.sol` (`1inch/aqua` v1.0.0) | the ABI subset we call | [`contracts/src/interfaces/IAqua.sol`](../../contracts/src/interfaces/IAqua.sol), which cites this path in its header |
| `src/SwapVM.sol`, function `_transferOut` (`1inch/swap-vm` v1.0.1) | the maker hook fires immediately **before** `AQUA.pull` and carries the settled `amountOut`. That single ordering fact is what makes exact-amount JIT withdrawal from Aave possible inside one transaction | [`contracts/src/PartyVault.sol`](../../contracts/src/PartyVault.sol) hook implementation |
| `src/interfaces/IMakerHooks.sol` (`1inch/swap-vm` v1.0.1) | the fixed 9-argument `preTransferOut` signature, selector `0x5a394f80`. It is not a payload we choose | [`contracts/src/interfaces/IMakerHooks.sol`](../../contracts/src/interfaces/IMakerHooks.sol) |
| the Aqua opcode/instruction list at `1inch/swap-vm` v1.0.1 | the instruction set the deployed router dispatches on | measured table in [`docs/VERIFIED.md`](../VERIFIED.md) |

On that last row, be precise about what we verified. We did not eyeball the upstream enum and hope.
The machine-readable mirror we used is `instructions.aquaInstructions` in
`@1inch/swap-vm-sdk@0.3.0`, and we proved it matches the deployed array by decoding all four live
generation-2 ships through `AquaProgramBuilder.decode()` and re-building them to byte-identical
program bytes. Reproduce with `pnpm verify:onchain`. An off-by-one table would have thrown on the
first instruction, and our first estimate did exactly that.

### npm packages, pinned exact

No carets anywhere. Opcode bytes are never hand-written; everything goes through
`AquaProgramBuilder`.

| Package | Version | npm | Used in |
|---|---|---|---|
| `@1inch/swap-vm-sdk` | `0.3.0` | [npmjs.com/package/@1inch/swap-vm-sdk](https://www.npmjs.com/package/@1inch/swap-vm-sdk) | [`scripts/lib/program.ts`](../../scripts/lib/program.ts), [`scripts/build-orders.ts`](../../scripts/build-orders.ts), [`scripts/taker.ts`](../../scripts/taker.ts), [`scripts/unwind.ts`](../../scripts/unwind.ts) |
| `@1inch/aqua-sdk` | `0.2.0` | [npmjs.com/package/@1inch/aqua-sdk](https://www.npmjs.com/package/@1inch/aqua-sdk) | [`scripts/lib/events.ts`](../../scripts/lib/events.ts), [`scripts/verify-onchain.ts`](../../scripts/verify-onchain.ts), the rehearsals |
| `@1inch/sdk-core` | `0.1.2` | [npmjs.com/package/@1inch/sdk-core](https://www.npmjs.com/package/@1inch/sdk-core) | `Interaction`, used to attach the maker hook |

Two SDK details that are not in any README and cost us time:

- The maker hook target rides a **zero-address** `Interaction`. Zero target means "call the maker
  itself", which is what the vault wants.
- The hook data must be **non-empty**: the SDK's `Interaction` asserts non-empty hex bytes. The router
  does not interpret it, it just forwards it as `makerHookData`.

### Deployed generations on Arbitrum One

| | Aqua registry | AquaSwapVMRouter | EIP-712 domain |
|---|---|---|---|
| Generation 1 (dead, and what the upstream READMEs document) | [`0x499943e7...6d31`](https://arbiscan.io/address/0x499943e74fb0ce105688beee8ef2abec5d936d31) | [`0x8fdd04db...0958f`](https://arbiscan.io/address/0x8fdd04dbf6111437b44bbca99c28882434e0958f) | ("AquaSwapVMRouter", "1.0.0") |
| **Generation 2 (live, what we use)** | [`0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a`](https://arbiscan.io/address/0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a) | [`0x1111113Db0e0ef9D0E3A50d5f094a3a57a26C0DE`](https://arbiscan.io/address/0x1111113Db0e0ef9D0E3A50d5f094a3a57a26C0DE) | ("1inch SwapVM v1.0", "1.0.2") |

Each router's `AQUA()` getter points at its own registry, so the pairs are fixed. We measured which
one is live rather than trusting documentation; see [`docs/VERIFIED.md`](../VERIFIED.md).

---

## 2. Aave v3

The carry venue. Idle vault USDC is supplied to Aave v3 and withdrawn on demand, including from
inside a settlement transaction.

| What | Where |
|---|---|
| Documentation | [docs.aave.com](https://docs.aave.com/) |
| Protocol source | [github.com/aave/aave-v3-core](https://github.com/aave/aave-v3-core) |

| Contract (Arbitrum One) | Address | How we verified it |
|---|---|---|
| Aave v3 Pool | [`0x794a61358D6845594F94dc1DB02A252b5b4814aD`](https://arbiscan.io/address/0x794a61358D6845594F94dc1DB02A252b5b4814aD) | matches the aToken's own `POOL()` getter |
| aArbUSDCn (aUSDC) | [`0x724dc807b04555b71ed48a6896b6F41593b8C637`](https://arbiscan.io/address/0x724dc807b04555b71ed48a6896b6F41593b8C637) | `UNDERLYING_ASSET_ADDRESS()` returns native USDC, `symbol()` is `aArbUSDCn`, 6 decimals |

Calls we make: `supply`, `withdraw`, and the aToken's `balanceOf` for the parked figure.
[`AaveV3Adapter`](../../contracts/src/AaveV3Adapter.sol) re-runs the aToken checks in its
constructor, so a mis-wired pair cannot deploy. Interface subset:
[`contracts/src/interfaces/IAaveV3.sol`](../../contracts/src/interfaces/IAaveV3.sol).

Measured on an Arbitrum fork of live state: JIT overhead per fill is 26,128 gas (92,494 with the
Aave withdrawal inside the fill versus 66,366 when the hot buffer covers it), and aUSDC carry over 90
warped days on 100k USDC implies 263 bps APR.

One operational note that is Aave behaviour and not a bug: the parked figure is routinely off by a
unit or two from a round number. That is Aave's scaled-balance rounding.

---

## 3. Chainlink

Price source for NAV. WETH held by the vault is valued at Chainlink; a non-positive answer is
rejected.

| What | Where |
|---|---|
| Data Feeds documentation | [docs.chain.link/data-feeds](https://docs.chain.link/data-feeds) |
| Feed address directory | [docs.chain.link/data-feeds/price-feeds/addresses](https://docs.chain.link/data-feeds/price-feeds/addresses), network Arbitrum One |
| ETH/USD on Arbitrum One | [`0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612`](https://arbiscan.io/address/0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612), 8 decimals |

Interface subset: [`contracts/src/interfaces/IPriceFeed.sol`](../../contracts/src/interfaces/IPriceFeed.sol).

We measured the feed's real cadence over 24 hours rather than assuming it: 360 updates, median gap
121 seconds, maximum gap 29.5 minutes. The designed 90-minute staleness bound therefore has no
false-trip margin risk. **The in-vault staleness gate itself was cut from the window** and is watched
off chain by the status script and the manager instead; see
[04_QUALIFICATION.md](./04_QUALIFICATION.md).

---

## 4. Standards

| Standard | Link | How we use it |
|---|---|---|
| ERC-20 | [eips.ethereum.org/EIPS/eip-20](https://eips.ethereum.org/EIPS/eip-20) | USDC (native, [`0xaf88d065e77c8cC2239327C5EDb3A432268e5831`](https://arbiscan.io/address/0xaf88d065e77c8cC2239327C5EDb3A432268e5831), **not** USDC.e) and WETH ([`0x82aF49447D8a07e3bd95BD0d56f35241523fBab1`](https://arbiscan.io/address/0x82aF49447D8a07e3bd95BD0d56f35241523fBab1)) |
| ERC-4626 | [eips.ethereum.org/EIPS/eip-4626](https://eips.ethereum.org/EIPS/eip-4626) | share math with a decimals offset. We implement the math, **not** the interface |
| EIP-712 | [eips.ethereum.org/EIPS/eip-712](https://eips.ethereum.org/EIPS/eip-712) | context: the router's domain separator is how we identified the live Aqua generation |

**On ERC-4626, be precise about what we did.** `PartyVault` deliberately does not inherit
OpenZeppelin's `ERC4626`, because that would drag in the transferable ERC-20 share token our rules
forbid (VLT-R3). Instead the share ledger is internal and non-transferable, and equivalence with the
standard is **proved rather than asserted**: a stock OpenZeppelin `ERC4626` with the same decimals
offset is driven through the same sequence and the results are compared, in
[`contracts/test/PartyVaultShareMath.t.sol`](../../contracts/test/PartyVaultShareMath.t.sol) (6
differential tests).

| Library | Link | Use |
|---|---|---|
| OpenZeppelin Contracts | [github.com/OpenZeppelin/openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts), docs at [docs.openzeppelin.com/contracts](https://docs.openzeppelin.com/contracts) | git submodule. `SafeERC20`, `IERC20`, and `ERC4626` as the differential reference |

---

## 5. Tooling

| Tool | Version | Link |
|---|---|---|
| Foundry (forge, cast, anvil) | current | [book.getfoundry.sh](https://book.getfoundry.sh) |
| Solidity | `0.8.28`, optimizer on, 1,000,000 runs, `evm_version = cancun` | [`contracts/foundry.toml`](../../contracts/foundry.toml) |
| forge-std | git submodule | [github.com/foundry-rs/forge-std](https://github.com/foundry-rs/forge-std) |
| viem | `2.38.6` | [viem.sh](https://viem.sh) |
| vitest | `3.2.4` | [vitest.dev](https://vitest.dev) |
| tsx | `4.20.6` | [github.com/privatenumber/tsx](https://github.com/privatenumber/tsx) |
| TypeScript | `5.9.3` | [typescriptlang.org](https://www.typescriptlang.org) |
| pnpm | `11.5.0`, Node 22+ | [pnpm.io](https://pnpm.io) |

Cancun is safe here: Arbitrum One runs an ArbOS release with full Cancun support, and the live Aqua
registry is itself compiled for it.

Gates:

```bash
forge test --root contracts   # 62 tests: 38 vault unit, 6 ERC-4626 differential,
                              # 13 adapter fork, 5 launch fork
pnpm gate                     # tsc --noEmit + vitest (band math)
pnpm verify:onchain           # read-only ground truth against Arbitrum mainnet
pnpm fork:all                 # rehearsal + traps + taker on a throwaway fork
```

Fork suites run against live Arbitrum through a public endpoint by default and re-verify every
`AddressBook` entry against the chain, so the docs cannot rot silently.

---

## 6. Our own artifacts

| Artifact | Where |
|---|---|
| Repository (public, MIT) | [github.com/0xmvercosa/pool-party-aqua](https://github.com/0xmvercosa/pool-party-aqua) |
| `PartyVault` (deployed, verified) | [`0xec870a6A9E8EE41B349FD0766b8f295D6EDC6610`](https://arbiscan.io/address/0xec870a6A9E8EE41B349FD0766b8f295D6EDC6610#code) |
| `AaveV3Adapter` (deployed, verified) | [`0x6d409fF8578D017AddDB2e9Ad0848D8F0A65aBAe`](https://arbiscan.io/address/0x6d409fF8578D017AddDB2e9Ad0848D8F0A65aBAe#code) |
| Manager / vault owner | [`0xc365B6795443380eb76516dA0Cedd5a00B349d66`](https://arbiscan.io/address/0xc365B6795443380eb76516dA0Cedd5a00B349d66) |
| Taker (separate wallet, no privilege) | [`0x67Fd51e5082205AF0bD97039a6124Ff3368aD0da`](https://arbiscan.io/address/0x67Fd51e5082205AF0bD97039a6124Ff3368aD0da) |
| Measured ground truth | [`docs/VERIFIED.md`](../VERIFIED.md) |
| Settlement proofs, with the JIT trace decoded | [`docs/FILLS.md`](../FILLS.md) |
| Fork settlement proofs | [`docs/FILLS_FORK.md`](../FILLS_FORK.md) |
| Numbered, versioned business rules | [`docs/01_BUSINESS_RULES.md`](../01_BUSINESS_RULES.md) |
| Operations: deploy, seed, ship, roll, stop, close out, key handling | [`RUNBOOK.md`](../../RUNBOOK.md) |
| Full reproduction walkthrough | [`docs/05_DEMO_WALKTHROUGH.md`](../05_DEMO_WALKTHROUGH.md) |
| Canonical addresses in code, each with how it was verified | [`contracts/src/AddressBook.sol`](../../contracts/src/AddressBook.sol) |
| Committed ABIs plus a consumption guide | [`abis/`](../../abis) |
| Repository overview | [`README.md`](../../README.md) |

Planning artifacts (`docs/00_ARCHITECTURE_AND_PLAN.md`, `02_WORKPLAN.md`, `03_EXECUTION_PLAN.md`,
`04_KICKOFF_2TRACKS.md`) were written before and during the build. Treat them as process evidence.
Where they disagree with the code or with `VERIFIED.md`, the code and `VERIFIED.md` win.

Judge package: [README.md](./README.md), [01_WHAT_WE_BUILT.md](./01_WHAT_WE_BUILT.md),
[02_ARCHITECTURE.md](./02_ARCHITECTURE.md), [03_INTEGRATIONS.md](./03_INTEGRATIONS.md),
[04_QUALIFICATION.md](./04_QUALIFICATION.md), [06_ROADMAP.md](./06_ROADMAP.md),
[07_PROCESS.md](./07_PROCESS.md).

---

## 7. Licensing and attribution

### 1inch Aqua and SwapVM are source-available, not OSI open source

They are licensed by their owner under `LicenseRef-Degensoft-Aqua-Source-1.1` and
`LicenseRef-Degensoft-SwapVM-1.1`. Non-commercial use, explicitly including hackathons, is free.
Anyone considering commercial use must read those licenses first. Nothing in this repository
relicenses them.

### No upstream source is vendored here

This matters and it is checkable. Our contracts restate **only** the ABI shapes they call, and each
such file names the upstream tag it was transcribed from in its header:

- [`contracts/src/interfaces/IAqua.sol`](../../contracts/src/interfaces/IAqua.sol) cites
  `1inch/aqua` tag `v1.0.0`, `src/interfaces/IAqua.sol`.
- [`contracts/src/interfaces/IMakerHooks.sol`](../../contracts/src/interfaces/IMakerHooks.sol) cites
  `1inch/swap-vm` tag `v1.0.1`, `src/interfaces/IMakerHooks.sol`, and restates only
  `preTransferOut` out of the four hooks upstream declares.

The git submodules in this repository are OpenZeppelin Contracts and forge-std, both MIT. Neither
Aqua nor SwapVM is a submodule, a copy, or a fork here.

Had `PartyRouter` shipped (it did not, see [04_QUALIFICATION.md](./04_QUALIFICATION.md)), it would be
a redeploy of modified SwapVM source and its source would be published under the license's copyleft
terms.

### Attribution, quoted verbatim as the license requires

> Aqua — © Degensoft Ltd 2025

That string is reproduced exactly as the upstream license writes it, punctuation included.

### Our license

Everything original in this repository (PartyVault, AaveV3Adapter, the scripts, the documentation) is
MIT: [`LICENSE`](../../LICENSE). Its scope note states the boundary plainly, that this code calls the
1inch contracts but is not derivative of them.

### Data and secrets

No secrets, private keys, RPC credentials or production data are committed. Environment values live
only in local `.env` files, and [`.env.example`](../../.env.example) carries names without values.
