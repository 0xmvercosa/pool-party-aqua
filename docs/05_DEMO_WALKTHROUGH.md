# Active Reserve: full reproduction walkthrough (Arbitrum mainnet)

Every command needed to take Active Reserve from an empty machine to a live strategy settling
real fills, ending on the numbers screen. This is the sequence used for the judges' demo, and it
is the same sequence anyone can run to reproduce our claims.

**Runtime:** about 15 minutes, roughly 0.30 USD of gas. **Money at risk:** the seed (9.5 USDC)
plus the taker's working capital, both recoverable at the end.

Read [VERIFIED.md](./VERIFIED.md) first if you want the ground truth this rests on: the live
Aqua generation, the measured opcode table, and the maker-hook signature.

---

## 0. What you need before starting

| Item | Detail |
|---|---|
| Foundry | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` |
| Node 22 + pnpm | `corepack enable` after installing Node |
| Manager wallet | Deploys, seeds, ships, docks. Needs about **9.6 USDC (native, `0xaf88...5831`, NOT USDC.e) + 0.003 ETH** on Arbitrum One |
| Taker wallet | Separate wallet, fills like any other taker. Needs about **0.0004 WETH + 0.0004 ETH** |
| Arbiscan API key | Free at arbiscan.io, only used for source verification |

Both wallets are plain EOAs. The taker is deliberately a different wallet: it holds only its own
working capital and has no privileged access to the vault (BOT-R4).

## 1. Clone and install

```bash
git clone https://github.com/0xmvercosa/pool-party-aqua.git && cd pool-party-aqua
```

```bash
git submodule update --init --recursive && pnpm install
```

## 2. Configure the environment

```bash
cp .env.example .env
```

Fill in `.env`: `ARBISCAN_API_KEY`, `MANAGER_PRIVATE_KEY`, `MANAGER_ADDRESS`,
`TAKER_BOT_PRIVATE_KEY`. Leave the launch parameters as they ship (seed 9.5 USDC, 5 percent hot
buffer, bands 0.60 and 0.35 USDC). `VAULT_ADDRESS` stays empty until step 4.

The raw manager key is used so a live demo never stops at a password prompt. If you prefer a
keystore, run `cast wallet import manager --interactive` and replace
`--private-key "$MANAGER_PRIVATE_KEY"` with `--account manager` in every command below.

## 3. Prove the ground truth before spending anything

```bash
cd contracts && forge test && cd ..
```

62 tests: vault units, a differential suite against OpenZeppelin ERC-4626, and two Arbitrum fork
suites that re-verify every address against the live chain and rehearse the whole launch
sequence against the **real** Aqua registry.

```bash
set -a && source .env && set +a && pnpm verify:onchain
```

Read-only against mainnet. It proves which Aqua generation is live, decodes the four live
production programs, and round-trips them through our builder to byte-identical bytes.

## 4. Deploy the vault and the adapter

```bash
set -a && source .env && set +a && cd contracts && forge script script/Deploy.s.sol:DeployActiveReserve --rpc-url "$ARBITRUM_RPC_URL" --broadcast --verify --private-key "$MANAGER_PRIVATE_KEY" --sender "$MANAGER_ADDRESS" && cd ..
```

The script predicts the vault address, constructs the adapter bound to it, and asserts the pair
during simulation, so a mis-wired deployment aborts before anything is broadcast.

Record the printed `PartyVault` address in `.env` as `VAULT_ADDRESS`.

If `--verify` fails on the deprecated V1 endpoint, verify through the Etherscan V2 API:
`forge verify-contract <ADDR> src/PartyVault.sol:PartyVault --verifier-url 'https://api.etherscan.io/v2/api?chainid=42161' --etherscan-api-key "$ARBISCAN_API_KEY" --constructor-args $(cast abi-encode ...)`.

## 5. Seed and park

```bash
set -a && source .env && set +a && cd contracts && forge script script/Ops.s.sol:SeedAndPark --rpc-url "$ARBITRUM_RPC_URL" --broadcast --private-key "$MANAGER_PRIVATE_KEY" --sender "$MANAGER_ADDRESS" && cd ..
```

One signed run: approve, deposit 9.5 USDC, park 95 percent into Aave v3. Expect roughly 0.475
USDC hot and 9.025 USDC earning supply yield from the next block onward. The manager must seed
first; every other deposit reverts `NotSeeded` until then (VLT-R2).

## 6. Compile the two strategy programs

```bash
set -a && source .env && set +a && pnpm tsx scripts/build-orders.ts
```

Reads the Chainlink spot, builds both bands as SwapVM programs in the measured canonical order
`[deadline][concentrate][flatFee 80bps][xycSwapXD][salt]`, and prints, per band, the decoded
instruction list, the `strategyHash`, the matching `SHIP_USDC`, and the ABI-encoded `ORDER_BYTES`.

Copy both `strategyHash` values somewhere: the fills need them.

## 7. Ship both bands

Export the DEMO band values printed above, then ship:

```bash
export ORDER_BYTES=<demo ORDER_BYTES> SHIP_USDC=600000
```

```bash
set -a && source .env && set +a && cd contracts && forge script script/Ops.s.sol:ShipBand --rpc-url "$ARBITRUM_RPC_URL" --broadcast --private-key "$MANAGER_PRIVATE_KEY" --sender "$MANAGER_ADDRESS" && cd ..
```

Now the PRODUCTION band:

```bash
export ORDER_BYTES=<production ORDER_BYTES> SHIP_USDC=350000
```

```bash
set -a && source .env && set +a && cd contracts && forge script script/Ops.s.sol:ShipBand --rpc-url "$ARBITRUM_RPC_URL" --broadcast --private-key "$MANAGER_PRIVATE_KEY" --sender "$MANAGER_ADDRESS" && cd ..
```

Shipping moves no tokens: it writes virtual balances in the Aqua registry. The vault's
`totalAssets` is identical before and after, which is the whole point of the model.

## 8. Smoke test

```bash
set -a && source .env && set +a && cd contracts && forge script script/Ops.s.sol:Smoke --rpc-url "$ARBITRUM_RPC_URL" && cd ..
```

Read-only. Expect: seeded true, `totalAssets` at the seed (or a tick above, the Aave carry is
already running), the hot/parked split, and two active strategies carrying the shipped USDC with
WETH at 0.

## 9. The three fills

Quote first. Dry-run is the default: nothing is sent without `--execute`.

```bash
set -a && source .env && set +a && pnpm taker --strategy <DEMO_HASH> --size 0.0003 --network mainnet
```

**Fill 1, the money shot.** 0.0003 WETH is worth more than the hot buffer, so the vault has to
withdraw from Aave inside the settlement transaction:

```bash
set -a && source .env && set +a && pnpm taker --strategy <DEMO_HASH> --size 0.0003 --network mainnet --execute
```

Watch for `JIT PATH HIT`. Open that transaction on Arbiscan: one transaction contains the aUSDC
burn (the Aave withdrawal), the Aqua `Pulled` (USDC leaving the vault for the taker), and the
WETH `push` back into the vault. That single trace is the product.

**Fill 2**, same band, now with an empty buffer, so it is served straight from Aave:

```bash
set -a && source .env && set +a && pnpm taker --strategy <DEMO_HASH> --size 0.00002 --network mainnet --execute
```

**Fill 3**, the PRODUCTION band, proving the second strategy settles too:

```bash
set -a && source .env && set +a && pnpm taker --strategy <PRODUCTION_HASH> --size 0.00002 --network mainnet --execute
```

Every fill binds the quote on-chain through a TakerTraits threshold (quote minus 50 bps), obeys a
per-fill and a daily cap, and appends a row to `docs/FILLS.md`.

## 10. The numbers screen

```bash
set -a && source .env && set +a && pnpm status --vault $VAULT_ADDRESS --strategy <DEMO_HASH> --strategy <PRODUCTION_HASH> --network mainnet
```

Everything is read fresh from chain. What to point at:

- **NAV** reconstructed off wallet balances, the Aave position and Chainlink, cross-checked
  against the vault's own `totalAssets()` on-chain: the diff should be 0.
- **Carry**: real Aave interest, computed as the parked balance minus net principal parked.
- **Fills**: WETH accumulated, average price paid, and the discount versus spot. That is the
  dip-buying leg, in numbers.
- **Coverage**: liquid USDC against what the strategies quote.

## 11. Close out (optional, when the demo is over)

Order matters. Selling the accumulated WETH back has to happen BEFORE the emergency stop,
because the stop revokes the allowances and docks the strategies, which is the only route the
inventory has out. A buy band never approves WETH to Aqua on its own (it only ever sells USDC),
so grant it explicitly first:

```bash
set -a && source .env && set +a && cast send $VAULT_ADDRESS "revokeAquaApproval(address,uint256)" 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 $(cast call 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 "balanceOf(address)(uint256)" $VAULT_ADDRESS --rpc-url $ARBITRUM_RPC_URL | awk '{print $1}') --rpc-url $ARBITRUM_RPC_URL --private-key "$MANAGER_PRIVATE_KEY"
```

```bash
set -a && source .env && set +a && pnpm tsx scripts/unwind.ts --strategy <DEMO_HASH> --usdc-in 0.55 --network mainnet --execute
```

Then the stop, the cap, and the redemption:

```bash
set -a && source .env && set +a && cd contracts && forge script script/Ops.s.sol:EmergencyStop --rpc-url "$ARBITRUM_RPC_URL" --broadcast --private-key "$MANAGER_PRIVATE_KEY" --sender "$MANAGER_ADDRESS" && cd ..
```

```bash
set -a && source .env && set +a && cast send $VAULT_ADDRESS "setMaxTvl(uint256)" 0 --rpc-url $ARBITRUM_RPC_URL --private-key "$MANAGER_PRIVATE_KEY"
```

```bash
set -a && source .env && set +a && SHARES=$(cast call $VAULT_ADDRESS "convertToShares(uint256)(uint256)" $(cast call $VAULT_ADDRESS "liquidUsdc()(uint256)" --rpc-url $ARBITRUM_RPC_URL | awk '{print $1}') --rpc-url $ARBITRUM_RPC_URL | awk '{print $1}') && cast send $VAULT_ADDRESS "redeem(uint256)" $SHARES --rpc-url $ARBITRUM_RPC_URL --private-key "$MANAGER_PRIVATE_KEY"
```

Redemption pays USDC only (VLT-R5), so the command above redeems exactly what the vault can
serve in USDC. Any WETH still held stays as residual inventory backing the leftover shares.

## Things that will happen, and what they mean

**A fill reverts with an arithmetic underflow.** The band ran out of depth. Aqua's `pull` reverts
rather than over-committing, which is the no-bad-debt design: quote a smaller size or re-ship.

**A redemption reverts `InsufficientLiquidUsdc(requested, available)`.** The band bought WETH, so
the USDC side shrank. The value is intact, the liquidity is not. Redeem a smaller amount or sell
the inventory back first. Never call this a loss.

**The parked figure is a unit or two off a round number.** Aave scaled-balance rounding, not an
error.

## Honest framing for the demo

The fills here are **self-directed settlement proofs**: our own taker buying from our own
strategy to prove the machine settles end to end. They are not arbitrage profit and not organic
demand. A band that bids below spot cannot win arbitrage by construction; it becomes the best bid
only when the market actually falls into it, and then arbitrageurs fill it for their own reasons.
The external, real yield during any short window is the Aave carry, which accrues every block
whether anyone fills or not.
