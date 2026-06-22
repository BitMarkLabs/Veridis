import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname } from "node:path";
import { config } from "./config.js";
import type { Cursor, DbShape, StoredEvent, ClaimView } from "./types.js";

const EMPTY: DbShape = {
  cursors: {},
  events: [],
  claims: {},
  meta: { lastPollAt: null, packageId: config.packageId },
};

class Store {
  private db: DbShape = structuredClone(EMPTY);
  private dirty = false;

  load(): void {
    try {
      if (existsSync(config.dataFile)) {
        this.db = JSON.parse(readFileSync(config.dataFile, "utf8")) as DbShape;
      }
    } catch (err) {
      console.error("[store] failed to read datastore, starting fresh:", err);
      this.db = structuredClone(EMPTY);
    }
    // If the package id changed, the old cursors/events are meaningless.
    if (this.db.meta?.packageId !== config.packageId) {
      console.warn("[store] package id changed — resetting index.");
      this.db = structuredClone(EMPTY);
      this.db.meta.packageId = config.packageId;
      this.dirty = true;
    }
  }

  persist(): void {
    if (!this.dirty) return;
    try {
      mkdirSync(dirname(config.dataFile), { recursive: true });
      writeFileSync(config.dataFile, JSON.stringify(this.db, null, 2));
      this.dirty = false;
    } catch (err) {
      console.error("[store] failed to persist datastore:", err);
    }
  }

  getCursor(module: string): Cursor | null {
    return this.db.cursors[module] ?? null;
  }
  setCursor(module: string, cursor: Cursor | null): void {
    this.db.cursors[module] = cursor;
    this.dirty = true;
  }

  hasEvent(id: string): boolean {
    return this.db.events.some((e) => e.id === id);
  }
  addEvent(ev: StoredEvent): void {
    this.db.events.push(ev);
    this.dirty = true;
  }

  upsertClaim(view: ClaimView): void {
    this.db.claims[view.claimId] = view;
    this.dirty = true;
  }
  getClaim(id: string): ClaimView | undefined {
    return this.db.claims[id];
  }

  markPolled(): void {
    this.db.meta.lastPollAt = Date.now();
    this.dirty = true;
  }

  // Read accessors for the API.
  listEvents(): StoredEvent[] {
    return this.db.events;
  }
  listClaims(): ClaimView[] {
    return Object.values(this.db.claims);
  }
  meta() {
    return this.db.meta;
  }
}

export const store = new Store();
