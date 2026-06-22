import { sui } from "./sui.js";
import { config, MODULES, isPackageConfigured } from "./config.js";
import { store } from "./store.js";
import { stateLabel } from "./constants.js";
import type { ClaimView, StoredEvent } from "./types.js";

function shortName(type: string): string {
  const parts = type.split("::");
  return parts[parts.length - 1] ?? type;
}
const num = (v: unknown): number => Number(v as never);
const str = (v: unknown): string => String(v as never);

/** Apply a single claim-related event to the aggregated claim view. */
function applyToClaim(ev: StoredEvent): void {
  const p = ev.parsedJson;
  const claimId =
    (p.claim_id as string) ?? (ev.name === "ClaimSubmitted" ? (p.claim_id as string) : undefined);
  if (!claimId) return;

  const existing = store.getClaim(claimId);
  const view: ClaimView =
    existing ?? {
      claimId,
      state: "UNKNOWN",
      disputed: false,
      submittedAt: null,
      updatedAt: null,
      history: [],
    };

  switch (ev.name) {
    case "ClaimSubmitted":
      view.policyId = str(p.policy_id);
      view.claimant = str(p.claimant);
      view.perilCode = num(p.peril_code);
      view.stateCode = 0;
      view.state = stateLabel(0);
      view.submittedAt = ev.timestampMs;
      break;
    case "ClaimStateChanged": {
      const to = num(p.to_state);
      view.stateCode = to;
      view.state = stateLabel(to);
      break;
    }
    case "ClaimApproved":
      view.approvedAmount = str(p.approved_amount);
      break;
    case "ClaimRejected":
      view.rejectionReasonCode = num(p.reason_code);
      break;
    case "ClaimDisputed":
      view.disputed = true;
      break;
    case "PaymentSettled":
      view.paidAmount = str(p.amount);
      view.payee = str(p.payee);
      view.settledAt = ev.timestampMs;
      break;
    default:
      return; // not a claim event
  }

  view.updatedAt = ev.timestampMs;
  view.history.push({
    name: ev.name,
    stateLabel: view.state,
    timestampMs: ev.timestampMs,
    txDigest: ev.txDigest,
  });
  store.upsertClaim(view);
}

const CLAIM_EVENTS = new Set([
  "ClaimSubmitted",
  "ClaimStateChanged",
  "ClaimApproved",
  "ClaimRejected",
  "ClaimDisputed",
  "PaymentSettled",
]);

async function pollModule(module: string): Promise<number> {
  let added = 0;
  let cursor = store.getCursor(module);
  let pages = 0;

  // Catch up across multiple pages, but cap pages per cycle to stay responsive.
  while (pages < 20) {
    pages++;
    const res = await sui.queryEvents({
      query: { MoveEventModule: { package: config.packageId, module } },
      cursor: cursor ?? undefined,
      limit: config.pageLimit,
      order: "ascending",
    });

    for (const ev of res.data) {
      const id = `${ev.id.txDigest}:${ev.id.eventSeq}`;
      if (store.hasEvent(id)) continue;
      const stored: StoredEvent = {
        id,
        txDigest: ev.id.txDigest,
        eventSeq: ev.id.eventSeq,
        module: (ev.transactionModule as string) ?? module,
        name: shortName(ev.type),
        type: ev.type,
        sender: ev.sender,
        timestampMs: ev.timestampMs ? Number(ev.timestampMs) : null,
        parsedJson: (ev.parsedJson as Record<string, unknown>) ?? {},
      };
      store.addEvent(stored);
      if (CLAIM_EVENTS.has(stored.name)) applyToClaim(stored);
      added++;
    }

    if (res.nextCursor) {
      cursor = { txDigest: res.nextCursor.txDigest, eventSeq: res.nextCursor.eventSeq };
      store.setCursor(module, cursor);
    }
    if (!res.hasNextPage) break;
  }
  return added;
}

export async function pollOnce(): Promise<void> {
  if (!isPackageConfigured()) {
    console.warn(
      "[indexer] VERIDIS_PACKAGE_ID is not set (still 0x0). " +
        "Publish the package and set it in .env — polling is idle until then.",
    );
    return;
  }
  let total = 0;
  for (const module of MODULES) {
    try {
      total += await pollModule(module);
    } catch (err) {
      console.error(`[indexer] poll error for module "${module}":`, (err as Error).message);
    }
  }
  store.markPolled();
  store.persist();
  if (total > 0) console.log(`[indexer] indexed ${total} new event(s).`);
}

export function startIndexer(): void {
  const tick = async () => {
    await pollOnce();
    setTimeout(tick, config.pollIntervalMs);
  };
  void tick();
  console.log(`[indexer] polling every ${config.pollIntervalMs}ms on ${config.rpcUrl}`);
}
