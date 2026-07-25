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
the public endpoint by default (`ARBITRUM_RPC_URL` overrides it). 66 tests at the time of writing:
38 vault unit, 6 differential against OpenZeppelin ERC-4626, 13 adapter fork, 9 launch fork.

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
forge script contracts/script/Deploy.s.sol:DeployActiveReserve \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --verify --ledger
```

The script deploys `AaveV3Adapter` and then `PartyVault`. The two reference each other immutably, so
it predicts the vault address, constructs the adapter with it, and asserts the pair afterwards.
Those assertions run during simulation, **before** anything is broadcast: a wrong prediction aborts
the run instead of publishing a mis-wired pair. It also refuses any chain other than Arbitrum One, a
zero manager, and a `maxTvl` above the window cap.

Record in `docs/VERIFIED.md` and in the launch record (section 10): adapter address, vault address, both deploy tx
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

### 1b. Verify the deployment ON CHAIN before spending a cent (mandatory gate)

`Deploy.s.sol` asserts the wiring, but those `require`s run inside forge's **simulation**. They prove
what the script intended to publish, not what a full node now actually serves. Close that gap before
the seed:

```bash
export VAULT_ADDRESS=0x...          # from the deploy output
forge script contracts/script/Ops.s.sol:VerifyDeployment --rpc-url "$ARBITRUM_RPC_URL"
```

Read-only, no broadcast, no signature needed. It reads every immutable back off live state and
reverts if anything is wrong: that the adapter is bound to **this** vault (the one fact a simulation
cannot establish), that both addresses hold code, that the router and registry are the gen-2 pair,
that USDC, WETH, the price feed, the Aave pool, the underlying and the aToken are all the canonical
addresses, that the owner is the manager who signed, that the decimals offset is 3, and that the
vault is genuinely fresh: unseeded, no strategies, no shares.

Expected output ends with `ON-CHAIN VERIFICATION PASSED` and `Safe to proceed to the seed step.`

**A revert here means STOP.** Do not seed a vault whose wiring does not check out; redeploy instead.
Because it insists the vault is unseeded, this is a one-time gate and not a health check: for
ongoing state use `Smoke` (section 4).

The same checks are callable directly, which is how the fork suite exercises them
(`LaunchForkTest.test_verifyDeployment_*`, including the rejection paths):

```bash
cast call <VERIFIER> "check(address,address)" "$VAULT_ADDRESS" "$MANAGER_ADDRESS" \
  --rpc-url "$ARBITRUM_RPC_URL"
```

## 2. Seed and park (POO-1062 R3, VLT-R2)

The manager must make the first deposit; every other deposit reverts `NotSeeded` until then.

```bash
export VAULT_ADDRESS=0x...
export SEED_USDC=200000000     # 200 USDC, within the D3 window band of 50 to 200
export BUFFER_BPS=500          # keep 5 percent hot (D5), park the rest

forge script contracts/script/Ops.s.sol:SeedAndPark \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --ledger
```

This approves, deposits, and parks in one signed run. Afterwards `Smoke` (section 4) must show a
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
forge script contracts/script/Ops.s.sol:ShipBand \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --ledger

export ORDER_BYTES=0x...       # demo band, spot -0.3% to -0.1%, distinct salt
export SHIP_USDC=8000000
forge script contracts/script/Ops.s.sol:ShipBand \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --ledger
```

Record both `strategyHash` values and both ship tx hashes. The vault stores the shipped token list
per hash, because Aqua's `dock` reverts unless it receives the complete list.

Shipping moves no tokens. It is an accounting write in the Aqua registry, which is why the vault's
`totalAssets` is identical before and after.

## 4. Smoke test (POO-1062 R6)

```bash
forge script contracts/script/Ops.s.sol:Smoke --rpc-url "$ARBITRUM_RPC_URL"
```

Read-only, safe to run at any time including mid-demo. Check:

- `totalAssets` equals the seed, give or take Aave rounding
- hot buffer and parked split match section 2
- `adapter`, `router (Aqua app)` and `aqua registry` are the addresses from section 1b
- all four allowance lines: `allow USDC -> Aqua` is set, and **`allow USDC -> router` and
  `allow WETH -> router` are both zero**. Aqua pulls from the maker; the router never needs an
  allowance, so anything non-zero there is a finding. The script prints a `WARNING` line of its own
  if either is non-zero
- both strategies listed with the USDC virtual balance you shipped and WETH at 0

Then Track B's side: `quote()` at three sizes against each strategy, matching compiler expectations.
Do not announce anything until both halves agree.

## 5. Rolling a band

A roll is `dock(old)` plus `ship(new)`. Two accounting writes, no token movement, no slippage.

**Step 1, dock the old band.** Take the `strategyHash` from the launch record in section 10:

```bash
export VAULT_ADDRESS=0x...
export STRATEGY_HASH=0x...          # the hash being retired

forge script contracts/script/Ops.s.sol:DockBand \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --ledger
```

`DockBand` refuses a hash the vault does not have active, and re-reads the state afterwards to
confirm it really went inactive. It needs no token argument: Aqua demands the complete shipped token
list and the vault stores and replays it.

Equivalent without the script, if you prefer a bare call:

```bash
cast send "$VAULT_ADDRESS" "execDock(bytes32)" "$STRATEGY_HASH" \
  --rpc-url "$ARBITRUM_RPC_URL" --ledger
```

**Step 2, ship the replacement** exactly as in section 3, with a program whose salt has changed.

To retire everything at once, use `EmergencyStop` (section 7) rather than docking one by one.

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
forge script contracts/script/Ops.s.sol:EmergencyStop \
  --rpc-url "$ARBITRUM_RPC_URL" --broadcast --ledger
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
| AaveV3Adapter | |
| PartyVault | |
| Deploy txs | |
| Arbiscan verification | |
| On-chain verification (section 1b) | |
| maxTvl at launch | |
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
