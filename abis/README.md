# ABI artifacts

Generated from `contracts/` and committed so the TypeScript rails (compiler, taker, status script,
frontend module) never import across repositories. Regenerate after any contract change:

```bash
bash contracts/script/export-abis.sh
```

## PartyVault

The Aqua maker. Track B calls it instead of the Aqua registry directly.

| Call | Who | Notes |
|---|---|---|
| `deposit(uint256 assets) returns (uint256 shares)` | anyone once seeded | USDC only. The manager must make the first deposit (VLT-R2). Reverts `MaxTvlExceeded`. |
| `redeem(uint256 shares) returns (uint256 assets)` | share holder | USDC only. Unparks the shortfall from Aave. Reverts `InsufficientLiquidUsdc` when buffer plus parked cannot cover it (VLT-R5). |
| `sharesOf(address)`, `convertToShares`, `convertToAssets`, `totalAssets`, `liquidUsdc` | view | ERC-4626 shaped. Shares are an internal ledger, NOT a token: there is no `balanceOf`, no `transfer`, no `totalSupply`. |
| `execShip(bytes order, address[] tokens, uint256[] amounts) returns (bytes32 strategyHash)` | owner | `order` is the ABI-encoded Order struct from the compiler (PRG-R9). The Aqua app is forced to the canonical router, the vault manages the Aqua allowance itself, and it records the token list for docking. |
| `execDock(bytes32 strategyHash)` | owner | No token argument: the vault replays the shipped token list, which Aqua requires in full. |
| `dockAll()` | owner | Emergency stop, accounting only (VLT-R11). |
| `revokeAquaApproval(address token, uint256 amount)` | owner | Second half of the emergency stop. |
| `parkUsdc(uint256)` / `unparkUsdc(uint256)` | owner | Manual hot-buffer management (the re-park keeper is cut for the window). |
| `preTransferOut(...)` | canonical router only | The upstream `IMakerHooks` maker hook. Never called by our own code. |
| `activeStrategies()`, `strategyTokens(bytes32)`, `isStrategyActive(bytes32)` | view | For the status script and the indexer. |

Events for the indexer: `Deposited`, `Redeemed`, `StrategyShipped`, `StrategyDocked`, `Parked`,
`Unparked`, `JitUnparked`, `MaxTvlUpdated`, `AquaApprovalSet`. `JitUnparked(token, amount,
strategyHash)` is the just-in-time proof: it lands in the same transaction as Aqua's `Pulled`.

### Order-building notes for the compiler (POO-1061)

- Set the maker-traits **pre-transfer-out hook flag with no explicit target**, so the router calls
  the maker, which is the vault. `makerData` may be empty; the vault ignores both `makerData` and
  the taker-controlled `takerData`.
- Ship **both tokens**, the empty side at amount 0 (PRG-R2). The vault stores that exact list and
  replays it on dock, because Aqua reverts `DockingShouldCloseAllTokens` otherwise.
- `strategyHash = keccak256(order)` and a docked hash is dead forever, so every roll must change
  the salt (PRG-R10).

## ICarryAdapter

The frozen `park` / `unpark` / `parkedBalance` seam. `AaveV3Adapter.json` is published once
POO-1060 lands.
