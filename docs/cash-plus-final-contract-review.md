# Cash+ independent contract review

Review date: 2026-09-13
Reviewed commit: `c7bd16c3743400facd8d711cb74c8ebd08efb78b` in `0xmvercosa/pool-party-aqua`
Scope: the eight Solidity files under `contracts/src/cashplus/`, their unit and integration tests, the pinned SwapVM hook/Extruction implementation, and selected frontend deployment bindings.
Status: review stopped when the user changed the immediate scope to a mocked UI demo. No deployment was performed and no contract source was changed by this reviewer.

## Conclusion

This bounded review did not identify a critical or high-severity exploit in the inspected custody, access-control, accounting, or settlement paths. It identified one low-severity pause-control issue and several operational constraints that must be addressed in any later deployment plan. This is a manual engineering review, not an external audit, a formal proof, or certification for production funds.

The existing contracts passed fresh tests against both mocks and official Arbitrum deployments. Those results demonstrate the covered scenarios; they do not establish that every possible failure mode is safe.

## Finding CP-L01 — selective pausing unnecessarily depends on a healthy oracle

Severity: **Low**. Status: **Open; full pause provides a workaround**.

Evidence: `contracts/src/cashplus/CashPlusVault.sol:484–495`, particularly line 490.

`setPause(deposits, trading)` calls `ORACLE.prices()` whenever either requested flag is `false`. This includes a request that only adds a pause. For example, with both flags initially false and an expired price feed, a guardian attempting `setPause(false, true)` to stop trading encounters an oracle revert even though the call would not unpause anything. The same applies to pausing deposits alone.

Impact is limited because `setPause(true, true)` and `setEmergencyMode(true)` do not call the oracle. The affected caller can still stop both activities, subject to the tokens accepting allowance revocation.

Recommended later fix: require fresh prices only when a currently paused activity is actually being unpaused. Add a regression covering a stale feed, a one-sided pause, and a genuine unpause. Until then, incident instructions should explicitly use the full-pause operation.

## Verified defenses

| Area | Observed behavior and evidence |
| --- | --- |
| Custody and roles | Shares are nontransferable and exits use the caller's own balance. Keeper/governance can manage only the supported assets and canonical router path. There is no arbitrary-call, upgrade, operator withdrawal, or rescue-to-operator function. Vault lines 159–197, 239–310, 430–507, 689–690. |
| Swap callbacks | All hooks authenticate the immutable router and vault maker. Empty hook data is required, the first seven arguments are bound across the four callbacks, and settlement state prevents cross-order/cross-function interleaving. Vault lines 525–623 and 665–680. |
| Allowances | The exact output allowance to Aqua is granted only after the input balance increase is verified; it is cleared after settlement. Vault and adapter approvals around Aave supply are also bounded and revoked. Vault lines 559–616 and 438–440; adapter lines 44–53. |
| NAV and shares | NAV counts held underlying, adapter idle underlying, and aToken balances; Aqua virtual allocations are excluded. A minimum 1,000 USDC seed is assigned to the nonredeemable seed holder. Deposits and exits have caller-supplied minimums. Vault lines 200–235, 259–310, 689–690 and 748–754. |
| Trade constraints | Quotes and hooks apply the same pricing/risk logic. Per-fill, daily-volume, inventory and buffer limits are enforced across orders. Policy changes invalidate earlier orders. Vault lines 509–623 and 637–699; Oracle lines 73–117. |
| Failure rollback | Covered Aave withdrawal failures revert the whole fill or redemption, preserving prior balances, shares and accounting. Official-fork and unit tests passed these scenarios. |
| Atomic deployment | The factory binds the CREATE2 salt to the caller, validates initializer/token bindings, transfers and checks the seed, and initializes in the same transaction. Factory lines 26–58. |

## Constraints for a future deployment

- **Roles cannot be rotated.** Governance, keeper and guardian are constructor immutables. The proposed deployer `0x67Fd51e5082205AF0bD97039a6124Ff3368aD0da` does not by itself determine the appropriate addresses for all three roles. A wrong address or lost key would require migration to another vault; Anvil actors must never be copied into a live configuration.
- **Emergency exits have dependencies.** Ordinary proportional redemption still reads the oracle. Oracle-free proportional exit requires governance or guardian to enable emergency mode first. Receipt transfers avoid an Aave withdrawal, but do not bypass aToken transfer restrictions, reserve pauses, issuer freezes or token failures. Emergency activation also calls the underlying tokens to revoke Aqua allowances. Evidence: Vault lines 292–309, 497–506 and 790–792.
- **Oracle guards do not guarantee market-value protection.** The tested configuration accepts price age and inter-feed skew up to 90,000 seconds, with a 50-basis-point peg threshold and 3,600-second sequencer grace period. These checks validate feed data; they cannot detect every market move before the feed updates. The USDT feed is used to value USD₮0, introducing a token/bridge-market assumption that requires explicit acceptance. A later launch must verify the feeds' actual heartbeat, deviation threshold and intended asset coverage.
- **Yield and liquidity are variable.** Aave supply balances and reported conversion spreads are not a guarantee of principal or a minimum return. USDC-only redemption needs sufficient USDC holdings and, when applicable, a successful Aave withdrawal. A proportional exit may return USD₮0 and aTokens.
- **The seed is permanently locked.** It is not a deployer deposit that can later be withdrawn. Any additional secondary-token funding sent directly to the vault is a donation shared through NAV, not separately owned sponsor capital.
- **Deterministic-address prefunding can prevent deployment.** A token donation to the predicted vault/component address is intentionally rejected by the constructor/factory. Select a fresh salt and recompute the address if this happens; never send seed funds to the predicted address manually. The atomic factory performs the seed transfer after creation.
- **Runtime and initcode have little spare space.** Preserve the reviewed compiler, optimization profile and constructor layout. Recalculate both limits after every Solidity change.
- **Deployment identity checks have limits.** The frontend checks chain ID, deployment-block hash and configured code hashes. Proxy runtime hashes alone do not detect upstream implementation upgrades, and cached hashes are not continuous monitoring. A later live launch still needs reviewed constructor parameters, official-address verification and post-deploy getter checks.
- **The existing operator CLI is fork-only.** Its loopback/chain-31337 checks and unlocked Anvil accounts are intentional. It is not a production Rabby deployment path. No final live manifest or live signing workflow was reviewed or approved here.

## Fresh verification evidence

Compilation settings: Solidity `0.8.28+commit.7893614a`, Cancun EVM, optimizer enabled with 200 runs, `viaIR=true`, profile `cashplus`.

| Check | Result |
| --- | --- |
| Cash+ unit/regression suite | 21 passed, including two fuzz tests with 512 runs each |
| Existing PartyVault unit suites | 44 passed |
| Existing launch/Aave fork suites | 22 passed |
| Cash+ official Aqua/SwapVM/Aave fork suite | 4 passed, 0 failed, 0 skipped |
| Vault deployed runtime | 24,486 bytes; 90 bytes below EIP-170's 24,576-byte limit |
| Vault creation bytecode | 47,681 bytes |
| Constructor arguments | 928 bytes |
| Complete vault initcode | 48,609 bytes; 543 bytes below EIP-3860's 49,152-byte limit |

The first test command below completed with 87 passed, 0 failed, 0 skipped. The separate Cash+ official-fork command completed with 4 passed, 0 failed, 0 skipped against fresh Arbitrum state; Foundry recorded upstream block `504776802` in that run. These were local fork simulations and did not broadcast mainnet transactions.

```sh
cd /Users/murilovercosa/Documents/Codex/2026-09-13/an/work/cash-plus-contracts/contracts

FOUNDRY_PROFILE=cashplus /Users/murilovercosa/.foundry/bin/forge test \
  --no-match-path 'test/cashplus/CashPlusOfficialFork.t.sol' -vv

CASH_PLUS_FORK_RPC_URL=https://arb1.arbitrum.io/rpc \
FOUNDRY_PROFILE=cashplus /Users/murilovercosa/.foundry/bin/forge test \
  --match-contract CashPlusOfficialForkTest -vv
```

The four Cash+ integration tests covered official quote/swap parity with Aave just-in-time liquidity and a USDC exit; output-first/oversized rejection; actual aToken proportional transfers; and rollback when Aave refuses withdrawal. These scenarios do not simulate every possible Aave or stablecoin incident.

No Slither run, formal verification, production transaction, or independent audit-company review was performed in this pass. No new contract changes or tests were introduced after the user narrowed the task to the mocked UI.
