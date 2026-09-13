# Cash+ contract integration

Cash+ is an isolated demo vault. It does not replace or change `PartyVault`, Active Reserve address constants or its compiler settings. The generated JSON artifacts under `contracts/out` are the ABI source of truth; `CashPlusTypes.sol` defines the client tuples.

Build and test from repository root:

```sh
FOUNDRY_PROFILE=cashplus forge build --root contracts --sizes
FOUNDRY_PROFILE=cashplus forge test --root contracts --match-path 'test/cashplus/*' -vv
CASH_PLUS_FORK_RPC_URL=http://127.0.0.1:8549 FOUNDRY_PROFILE=cashplus forge test --root contracts --match-path 'test/cashplus/*' -vv
```

The Cash+ profile uses Solidity 0.8.28, Cancun, via IR and 200 optimizer runs. This profile is required for EIP-170 size compliance. The default Active Reserve profile remains unchanged. Fork tests skip explicitly when `CASH_PLUS_FORK_RPC_URL` is absent; a skipped fork test is not protocol certification.

## Deployment and ABI

1. Deploy `CashPlusDeploymentFactory`.
2. Construct `initCode = CashPlusVault.creationCode || abi.encode(Config, Policy)` from the same compiled artifact that the manifest records.
3. Approve exactly the disclosed seed to the factory. Call `deploy(initCode, usdc, seed, salt)`; minimum seed is 1,000 USDC. The seed becomes locked ownership at `address(1)` and is excluded from sponsor/investor account cashflows.
4. The factory binds CREATE2 salt to `(msg.sender, salt)`, creates and seeds in one transaction, and emits `VaultDeployed`. `predict(sponsor, salt, keccak256(initCode))` gives the expected vault. It never controls existing vault funds. It is a generic creation-code transport, not a code-certification authority: verifier must compare deployed bytecode, arguments and linked getters against reviewed artifacts.
5. Vault creates immutable oracle/math helper, read-only lens, USDC adapter, optional secondary adapter, pricing extension and program factory. Read their addresses through `ORACLE`, `LENS`, `USDC_ADAPTER`, `SECONDARY_ADAPTER`, `PRICING` and `PROGRAM_FACTORY`. Neither helper has authority to move assets.
6. Constructor rejects supported-token prefunding at vault and adapter addresses. Use a fresh salt after a prefunding rejection. No public deposit can precede initialization.

`deposit`, `redeem`, `redeemAll` and `redeemProportional` match the specification. Shares are internal/nontransferable and have 18 decimals. Account cashflows are returned by `accountCashflows`; no fees are deducted. All four proportional component slots are always returned: `[USDC, secondary, aUSDC, secondary aToken]`. An absent secondary adapter uses zero address/amount in slot 3. The first two amounts include idle underlying donated into the corresponding adapter, so underlying is not lost from NAV or a proportional exit. Receipt transfers require the recipient's actual balance increase to meet the signed minimum. Nominal receipt amounts and valuation have Aave's inherent one-raw-unit rounding tolerance.

`status()` and `inventory()` remain readable during oracle failure. `valuationAvailable` controls whether `assetsUsdc`/inventory values are usable; zero is not a fallback valuation. `budgetDay` identifies the UTC day of the stored budget denominator; a new day is fixed at the first successful economic checkpoint/settlement, never by a view. Same-day deposits, cap changes, docking and rotation do not reset it. `rebalanceRequired` indicates concentration above cap; cash exits remain available if executable, while the quote/hook risk check blocks secondary-increasing trades beyond the cap.

## Canonical program and official compatibility

Pinned source: SwapVM v1.0.2, commit `32c687c2b73101fc26549e48fa1ff8a4d73afbac`. Local declarations restate the ABI only; the licensed upstream implementation is not vendored. The Aqua opcode array removes its first static-array element when converted to a dynamic array, giving deadline **13**, Extruction **32**, salt **20**.

Canonical traits are `(1 << 254) | (1 << 252) | (1 << 251) | (1 << 250) | (1 << 249)`. All hook slice offsets are zero; hooks target the maker, receive empty maker data and accept only empty taker hook data. Receiver defaults to maker. Program bytes are:

```
0d 05 <uint40 deadline>
20 1c <20-byte pricing address> <uint64 policyVersion>
14 20 <bytes32 salt>
```

Program length is 71 bytes. `CashPlusProgramFactory.build(params)` returns `(maker, traits, data)`. `encode(params)` is `abi.encode(order)` and `hash(params)` hashes the complete encoded order. Initial Aqua virtual balances are ship parameters and do not become NAV. Each ship must have a unique salt/hash and allocations no greater than actual current holdings; Aave supply may round the receipt balance down one raw unit, so derive allocations from reads, not the nominal supplied amount.

Exact-input taker flags are `0x61` (exact input, input first, transferFrom+Aqua.push), packed in the low 16 bits of the official 22-byte header. CLI must encode a threshold and deadline, leave callbacks disabled and use taker as recipient. Allowance is counterparty -> official router. During settlement, vault gives Aqua exactly the verified `amountOut` only in `preTransferOut`, then revokes it in `postTransferOut`. The four-hook vault-global state blocks output-first and cross-order/cross-function entry. VM per-order locking alone is not relied upon.

The Extruction sets only `amountOut`, leaves `amountIn`, virtual registers, `amountNetPulled` and next PC unchanged, and consumes no taker argument bytes. Exact-output requests explicitly revert. The immutable oracle helper implements fair price, spread and aggregate risk math for identical quote/hook checks. Quotes cannot guarantee Aave liquidity; simulate the complete swap too.

## Fork fixture and verification

The test fixture uses native Arbitrum USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`, the current USD₮0 representation at `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9`, Aave pool `0x794a61358D6845594F94dc1DB02A252b5b4814aD`, aUSDC `0x724dc807b04555b71ed48a6896b6F41593b8C637`, secondary aToken `0x6ab707Aca953eDAeFBc4fD23bA73294241490620`, Aqua `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a`, and SwapVM `0x111111338c5091E8440b67B168bAe16a668AC0De`.

Direct Chainlink USD feeds: USDC `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3`, USDT `0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7`, sequencer `0xFdB631F5EE196F0ed6FAa767959853A9F217697D`. Aave oracle wrapper addresses are not interchangeable with Chainlink AggregatorV3 feeds. The fixture uses 90,000-second freshness and cross-feed-skew windows, 3,600-second sequencer grace, 50 bps peg bound, 5 bps base spread, <=10 bps surcharge, 1% fill limit and 20% daily volume limit. These are disclosed demo settings, not production market-making calibration.

Tests execute actual deployed router and Aqua transfers, Aave supply/JIT withdraw, both receipt transfers and cash redemption; quote/filled quantities and balance deltas must match. Unit tests cover mixed decimals, donation/slippage protection, exact token transfers, accounting, hard bounds/roles, oracle failures, emergency exits, aggregate inventory/day limits and nested settlement attempts. One fork outage case deliberately mocks Aave's withdraw revert to prove that the real router input transfer and budget roll back together; successful Aave paths use deployed code.

There are no upgrades, arbitrary external calls, borrowing, keeper asset recipients or rescue methods. Economic conclusions and production readiness require further independent review and live executable-price checks; a small Chainlink spread is not proof of commercial profitability.
