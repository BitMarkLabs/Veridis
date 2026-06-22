import type { ModuleName } from "./config.js";

/** A normalized, stored on-chain event. */
export interface StoredEvent {
  /** Unique id: `${txDigest}:${eventSeq}` */
  id: string;
  txDigest: string;
  eventSeq: string;
  module: ModuleName | string;
  /** Short event name, e.g. "ClaimSubmitted". */
  name: string;
  /** Fully-qualified Move type. */
  type: string;
  sender: string;
  timestampMs: number | null;
  parsedJson: Record<string, unknown>;
}

/** A small lifecycle entry kept on each claim for an at-a-glance history. */
export interface ClaimHistoryEntry {
  name: string;
  stateLabel?: string;
  timestampMs: number | null;
  txDigest: string;
}

/** Aggregated, current-state view of a single claim. */
export interface ClaimView {
  claimId: string;
  policyId?: string;
  claimant?: string;
  perilCode?: number;
  stateCode?: number;
  state: string;
  approvedAmount?: string;
  paidAmount?: string;
  payee?: string;
  rejectionReasonCode?: number;
  disputed: boolean;
  submittedAt: number | null;
  updatedAt: number | null;
  settledAt?: number | null;
  history: ClaimHistoryEntry[];
}

/** Per-module pagination cursor (Sui EventId) for resumable polling. */
export interface Cursor {
  txDigest: string;
  eventSeq: string;
}

export interface DbShape {
  cursors: Partial<Record<string, Cursor | null>>;
  events: StoredEvent[];
  claims: Record<string, ClaimView>;
  meta: { lastPollAt: number | null; packageId: string };
}
