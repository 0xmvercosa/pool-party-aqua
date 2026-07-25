# Pool Party x 1inch Aqua (Hackathon): on-chain side

A new class of Pool Party managed strategy built on 1inch Aqua + SwapVM, live on Arbitrum. The first product (working name "Party Notes 90/10"): ~90% of vault capital earns Aave v3 yield at all times; ~10% quotes a buy-the-dip band below spot as a SwapVM program in Aqua mode. A maker hook withdraws from Aave inside the settlement transaction, so parked capital is quotable liquidity: capital earns interest until the exact second it buys the dip.

> Hackathon deliverable. Deployed under hard caps with our own capital; likely docked/paused after the event pending audit and licensing. Not investment advice; nothing here is a live retail product.

## What lives where

**This repo** (on-chain side): `contracts/` Foundry workspace (PartyVault, AaveV3Adapter, PartyRouter), deploy + fork-rehearsal scripts, canonical docs (`docs/`), and the submission artifacts (`VERIFIED.md`, `RUNBOOK.md`, `FILLS.md` as they land).

**pool-party-frontend, branch `feat/aqua-poo-1057-hackathon`** (app side, separate private repo): investor/manager surfaces plus the Next server side: an internal API module (`src/lib/aqua/api/`) that plays the backend's role (strategy persistence on a Postgres mirror + on-chain orchestration), thin server actions, and the keeper/taker scripts.

## Start here

- `docs/00_ARCHITECTURE_AND_PLAN.md`: full architecture, custody model, fees, phased plan (read the addenda block first)
- `docs/01_BUSINESS_RULES.md`: numbered, versioned business rules (single source of truth)
- `docs/02_WORKPLAN.md`: two-homes layout, issue map, parallel-session coordination, compressed schedule
- Linear: project "Aqua Strategies (1inch Hackathon)", epic POO-1057

## Hackathon qualification

1. Official Aqua + official AquaSwapVMRouter used unmodified for the core product; PartyRouter is the explicitly-allowed modified SwapVM redeploy (one instruction wired: OraclePriceAdjuster).
2. On-chain token transfers demonstrated with real fills on Arbitrum mainnet (see `docs/FILLS.md` when populated).
3. Phased commit history, PR per Linear issue.

## Licensing and security

1inch Aqua and SwapVM are source-available under Degensoft licenses (not OSS). The modified router's source is published here per the license's copyleft terms. Review the upstream licenses before any commercial use. No secrets and no production data are ever committed to this repo; env values live only in local `.env` files.
