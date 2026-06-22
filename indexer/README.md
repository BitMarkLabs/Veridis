# Veridis — Off-chain Indexer & Read API

A small, dependency-light backend that **reads the Veridis on-chain events**
(from the Sui Move protocol) and exposes them through a clean HTTP API.

It does **not** hold any private keys and never writes to chain — it only
*reads*. On-chain stays the source of truth; this service builds a fast,
queryable view (an "indexer") for dashboards, ops tooling, and the future AI
agent.

## What it indexes

It polls these modules and stores their PII-free events:

- `access_control` — RoleGranted / RoleRevoked
- `identity` — AttestationIssued / AttestationRevoked / AttestationBurned / ConsentGranted / ConsentRevoked
- `policy_registry` — PolicyIssued / Renewed / Suspended / Reinstated / Cancelled
- `claims` — ClaimSubmitted / ClaimStateChanged / ClaimApproved / ClaimRejected / ClaimDisputed
- `payments` — VaultCreated / VaultFunded / VaultWithdrawn / PaymentSettled

From the claim events it builds an aggregated **claim view** (current state,
amounts, payee, full lifecycle history) keyed by `claim_id`.

## Prerequisites

- Node.js 18+ (check: `node -v`)
- The Veridis package **published** on testnet, so you have its package id.
  Until then the service runs but stays idle (it will tell you).

## Setup (in WSL)

```bash
cd ~/dev            # or wherever you keep projects
# copy this folder here as `veridis-indexer`, then:
cd veridis-indexer
npm install
cp .env.example .env
```

Edit `.env` and set `VERIDIS_PACKAGE_ID` to the published package id
(`0x...`). Leave `SUI_RPC_URL` on testnet unless you published elsewhere.

## Run

```bash
npm run dev      # watch mode (restarts on edits)
# or
npm start        # plain run
```

You should see the API on `http://localhost:8787` and the indexer polling
every few seconds.

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| GET | `/health` | service status, package id, counts |
| GET | `/stats` | event/claim totals + claims grouped by state |
| GET | `/claims` | all claims (filter: `?state=PAID`) |
| GET | `/claims/:id` | one claim + its full on-chain event history |
| GET | `/events` | raw events (filter: `?module=claims&name=ClaimSubmitted&limit=50`) |

## Notes / next steps

- **Storage:** uses a simple JSON file (`./data/...`) so there are zero native
  build steps. For production swap `store.ts` for Postgres/SQLite — the rest of
  the code doesn't change.
- **Resumable:** it keeps a per-module cursor, so restarts continue where they
  left off. Changing the package id resets the index automatically.
- **No keys, read-only:** safe to run anywhere; it cannot move funds or sign.
- This is the foundation the **AI agent** will read from later (it answers
  "which claims are in which state" without touching chain directly).
