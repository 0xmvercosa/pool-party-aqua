# Active Reserve runbook (Arbitrum One)

Operational procedures for the on-chain side: deploy, seed, ship, roll, monitor, stop. Written for
[POO-1062](https://linear.app/yeildbay/issue/POO-1062) R5 and used live during the launch.

**Who signs what.** The manager key (Murilo) signs every privileged transaction: deploy, seed,
`parkUsdc`/`unparkUsdc`, `execShip`, `execDock`, `dockAll`, `setMaxTvl`, `revokeAquaApproval`. The
taker bot uses a separate wallet holding only its own working capital. The keeper role does not
exist in the window (cut with POO-1069), so every operation below is a deliberate manual action.

**Hard gate.** Nothing in this runbook may be executed against mainnet before
[POO-1058](https://linear.app/yeildbay/issue/POO-1058) is Done.

**Addresses.** Only `contracts/src/AddressBook.sol` and `docs/VERIFIED.md` carry canonical
addresses. `LaunchForkTest.test_addressBook_matchesTheChain` re-verifies each one against the chain,
including that the router's `AQUA()` getter points at the gen-2 registry, so the docs cannot rot
silently.

---

## 0. Before anything touches mainnet

```bash
forge test --root contracts
```

The whole suite must be green, fork suites included. Those run against live Arbitrum state through
the public endpoint by default (`ARBITRUM_RPC_URL` overrides it). 62 tests at the time of writing:
38 vault unit, 6 differential against OpenZeppelin ERC-4626, 13 adapter fork, 5 launch fork.

`LaunchForkTest.test_launchSequence_seedParkShipTwoBandsThenDockAll` is a full rehearsal of section
1 to 4 below against the **real** Aqua registry. Run it immediately before the live deploy: if it
passes, the only thing not yet exercised on real state is the router fill, which is what
POO-1058's rehearsal and the first taker fill cover.

Environment (local `.env`, never committed):

```bash
export ARBITRUM_RPC_URL=...
export ARBISCAN_API_KEY=...
export MANAGER_ADDRESS=0x...        # Murilo's manager wallet
export MAX_TVL_USDC=300000000       # 300 USDC, 6 decimals. Deploy refuses anything above 1000 USDC
```

---

## 1. Deploy (POO-1062 R1)

```bash
cd contracts && forge script script/Deploy.s.sol:DeployActiveReserve \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --verify --account manager --sender "$MANAGER_ADDRESS"
```

The script deploys `AaveV3Adapter` and then `PartyVault`. The two reference each other immutably, so
it predicts the vault address, constructs the adapter with it, and asserts the pair afterwards.
Those assertions run during simulation, **before** anything is broadcast: a wrong prediction aborts
the run instead of publishing a mis-wired pair. It also refuses any chain other than Arbitrum One, a
zero manager, and a `maxTvl` above the window cap.

Record in `docs/VERIFIED.md` and in section 8 below: adapter address, vault address, both deploy tx
hashes, and the block number.

**If `--verify` fails** (Arbiscan rate limits are common):

```bash
forge verify-contract <ADDRESS> contracts/src/PartyVault.sol:PartyVault \
  --chain arbitrum --watch \
  --constructor-args $(cast abi-encode \
    "constructor(address,address,address,address,address,address,address,uint256)" \
    <USDC> <WETH> <AQUA> <ROUTER> <ADAPTER> <FEED> <MANAGER> <MAX_TVL>)
```

Source publication is a hackathon requirement, not a nicety. Do not proceed to section 3 until both
contracts read as verified on Arbiscan.

## 2. Seed and park (POO-1062 R3, VLT-R2)

The manager must make the first deposit; every other deposit reverts `NotSeeded` until then.

```bash
export VAULT_ADDRESS=0x...
export SEED_USDC=200000000     # 200 USDC, within the D3 window band of 50 to 200
export BUFFER_BPS=500          # keep 5 percent hot (D5), park the rest

cd contracts && forge script script/Ops.s.sol:SeedAndPark \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --account manager --sender "$MANAGER_ADDRESS"
```

This approves, deposits, and parks in one signed run. Afterwards `Smoke` (section 5) must show a
hot buffer of 10 USDC and roughly 190 USDC parked and already accruing.

Expect the parked figure to be off by one USDC unit from a round number. That is Aave's
scaled-balance rounding, not an error.

## 3. Ship the two bands (POO-1062 R4)

Track B's compiler produces the ABI-encoded Order bytes. Sizing must respect PRG-R5 and PRG-R6:
the **combined** shipped USDC across both bands stays inside the 10 percent sleeve. On a 200 USDC
vault that is 20 USDC total, for example 12 production plus 8 demo.

```bash
export ORDER_BYTES=0x...       # production band, spot -15% to -5%
export SHIP_USDC=12000000
cd contracts && forge script script/Ops.s.sol:ShipBand \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --account manager --sender "$MANAGER_ADDRESS"

export ORDER_BYTES=0x...       # demo band, spot -0.3% to -0.1%, distinct salt
export SHIP_USDC=8000000
cd contracts && forge script script/Ops.s.sol:ShipBand \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --account manager --sender "$MANAGER_ADDRESS"
```

Record both `strategyHash` values and both ship tx hashes. The vault stores the shipped token list
per hash, because Aqua's `dock` reverts unless it receives the complete list.

Shipping moves no tokens. It is an accounting write in the Aqua registry, which is why the vault's
`totalAssets` is identical before and after.

## 4. Smoke test (POO-1062 R6)

```bash
cd contracts && forge script script/Ops.s.sol:Smoke --rpc-url "$ARBITRUM_RPC_URL"
```

Read-only, safe to run at any time including mid-demo. Check:

- `totalAssets` equals the seed, give or take Aave rounding
- hot buffer and parked split match section 2
- Aqua allowance is set for USDC and **zero for the router** (Aqua pulls, the router never does)
- both strategies listed with the USDC virtual balance you shipped and WETH at 0

Then Track B's side: `quote()` at three sizes against each strategy, matching compiler expectations.
Do not announce anything until both halves agree.

## 5. Rolling a band

A roll is `dock(old)` plus `ship(new)`. Two accounting writes, no token movement, no slippage.

```bash
cd contracts && forge script script/Ops.s.sol:ShipBand ...   # after an execDock of the old hash
```

**The salt must change.** Aqua marks a docked hash with a permanent sentinel, so re-shipping the
same order bytes reverts forever. `LaunchForkTest.test_dockedHashIsDeadOnTheRealRegistry` proves
this against the live registry. The compiler enforces it (PRG-R10); this is the operational reason
why.

## 6. Raising or lowering the cap (VLT-R10)

```bash
cast send "$VAULT_ADDRESS" "setMaxTvl(uint256)" <NEW_CAP_6DP> \
  --rpc-url "$ARBITRUM_RPC_URL" --ledger
```

Deliberate manager action, recorded on POO-1062. The post-event schedule (5k, then 20k after 48
clean hours) is out of the window per the amended D3.

## 7. Emergency stop

```bash
cd contracts && forge script script/Ops.s.sol:EmergencyStop \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --account manager --sender "$MANAGER_ADDRESS"
```

`dockAll()` zeroes the virtual balance of every active strategy, then the Aqua allowances for USDC
and WETH are revoked. After this the vault is inert: nothing can be pulled, nothing can be filled.

Docking is accounting only, so it **cannot fail for lack of liquidity**. That is deliberate: the
emergency stop must work in exactly the conditions where liquidity is the problem.

Investor redemption is unaffected. `LaunchForkTest` asserts the seed is fully recoverable after an
emergency stop.

Use it when: the price runs through the band floor beyond mandate bounds, the Chainlink feed goes
stale (the in-vault gate is deferred for the window, so this is a human watch), Aave shows
utilization stress, or anything upstream behaves unexpectedly. During the window the manager watch
plus `dockAll` **is** the price sentinel, because the keeper loop (POO-1069) and the oracle-guarded
router (POO-1063) are consciously cut.

## 8. The "temporarily illiquid" state, explained honestly

Redemption pays USDC only. The vault can pay out whatever sits in the hot buffer plus whatever the
adapter can withdraw from Aave. If that is not enough it reverts `InsufficientLiquidUsdc(requested,
available)` rather than paying partially or in kind.

Two ways to get there, both normal, neither insolvency:

1. **The band filled.** The vault sold USDC and holds WETH. NAV is intact (the WETH is valued at
   Chainlink), but the USDC side is smaller. Redeeming a smaller share works immediately; a full
   redemption waits until the WETH is rebalanced per mandate.
2. **Aave utilization spike.** The reserve cannot serve the withdrawal, so Aave reverts and the
   adapter lets that revert through. Retry when utilization normalizes.

Say it to investors as "temporarily illiquid", never "protected" and never a loss (FE-R6). The same
revert is what makes a fill fail rather than settle against liquidity the vault does not have.

## 9. Key handling

| Key | Holder | Can do | Cannot do |
|---|---|---|---|
| Manager | Murilo, hardware wallet | deploy, seed, park/unpark, ship, dock, dockAll, setMaxTvl, revoke Aqua approval | move funds to an arbitrary address, redeem someone else's shares, upgrade or pause-and-take |
| Taker bot | separate wallet, own small capital | fill our bands like any taker | anything privileged on the vault |

The vault owner is **immutable**: there is no ownership transfer and no renounce. Key rotation means
deploying a new vault, which is acceptable at window size and removes a whole class of admin risk.

Worst case if the manager key leaks: the attacker can ship bands and move the sleeve between the
buffer and Aave. They cannot withdraw to themselves. The response is `dockAll` plus
`revokeAquaApproval` from the same key if it is still under control, and investor redemption stays
open regardless.

## 10. Launch record

Filled in during the live run.

| Item | Value |
|---|---|
| AaveV3Adapter | `0x6d409fF8578D017AddDB2e9Ad0848D8F0A65aBAe` |
| PartyVault | `0xec870a6A9E8EE41B349FD0766b8f295D6EDC6610` |
| Deploy txs | adapter `0x3b2b729700b60f14d1b340382d2ade637161662656d933419b26647068a855ae` (block 487662396), vault `0x5b77b43198e12e0917a99d73c6238ee16b9531a429769b803daf53faf528263a` (block 487662407), total 0.0000686 ETH |
| Arbiscan verification | both Pass - Verified via Etherscan API V2 (2026-07-25) |
| maxTvl at launch | 200 USDC (seed 10 USDC per re-amended D3) |
| Seed tx / amount | |
| Park tx / amount | |
| Production band strategyHash / ship tx | |
| Demo band strategyHash / ship tx | |
| Smoke test output | |
| First fill (incl. the JIT trace) | see `docs/FILLS.md` |

## 11. Post-event epilogue

1. `EmergencyStop` (dock everything, revoke approvals).
2. `setMaxTvl(0)`.
3. Manager redeems the seed.
4. Rotate the database credential (security rail, unrelated to these contracts).
5. Close the decisions log on [POO-1057](https://linear.app/yeildbay/issue/POO-1057).
