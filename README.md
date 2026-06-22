# Veridis

On-chain insurance protocol on **Sui** — Move smart contracts, an off-chain
read indexer, and a live claims portal.

## Repository layout

| Path | What it is |
| --- | --- |
| [`contracts/`](./contracts) | Sui Move package: `access_control`, `identity`, `policy_registry`, `claims`, `payments`. Includes the testnet deployment manifest and an end-to-end happy-path demo script. |
| [`indexer/`](./indexer) | Dependency-light Node/TypeScript service that reads on-chain Veridis events and exposes a JSON read API **plus a built-in dashboard** at `http://localhost:8787`. Read-only — holds no keys. |
| [`docs/`](./docs) | Architecture, claim-module notes, and deployment object IDs. |

## Quick start

### 1. Contracts (Sui testnet)
The package is already published on testnet — see
[`contracts/deployment.testnet.json`](./contracts/deployment.testnet.json) for
the live object IDs. To run the full claim lifecycle on-chain:

```bash
cd contracts
chmod +x veridis-happy-path.sh
./veridis-happy-path.sh        # needs the sui CLI on testnet + python3
```

### 2. Indexer + dashboard
```bash
cd indexer
npm install
cp .env.example .env           # set VERIDIS_PACKAGE_ID to the published package id
npm start
```
Then open **http://localhost:8787** for the dashboard, or hit the API:

| Method | Path | Description |
| --- | --- | --- |
| GET | `/health` | service status, package id, counts |
| GET | `/stats` | event/claim totals + claims grouped by state |
| GET | `/claims` | all claims (filter: `?state=PAID`) |
| GET | `/claims/:id` | one claim + full on-chain event history |
| GET | `/events` | raw events (`?module=claims&name=ClaimSubmitted&limit=50`) |

## Architecture

On-chain stays the source of truth. The indexer builds a fast, queryable view
(claims grouped by state, full lifecycle history per claim) for dashboards, ops
tooling, and the future AI agent — without ever signing or moving funds.

See [`docs/`](./docs) for the full design.
