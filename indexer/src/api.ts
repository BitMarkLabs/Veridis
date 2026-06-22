import express from "express";
import { store } from "./store.js";
import { config, isPackageConfigured } from "./config.js";
import { DASHBOARD_HTML } from "./dashboard.js";

export function createApi() {
  const app = express();

  // Dashboard (served same-origin so it can read the JSON endpoints below).
  app.get("/", (_req, res) => {
    res.type("html").send(DASHBOARD_HTML);
  });

  app.get("/health", (_req, res) => {
    res.json({
      ok: true,
      packageConfigured: isPackageConfigured(),
      packageId: config.packageId,
      rpcUrl: config.rpcUrl,
      lastPollAt: store.meta().lastPollAt,
      counts: { events: store.listEvents().length, claims: store.listClaims().length },
    });
  });

  // GET /events?module=claims&name=ClaimSubmitted&limit=50
  app.get("/events", (req, res) => {
    const { module, name } = req.query as { module?: string; name?: string };
    const limit = Math.min(Number(req.query.limit ?? 100), 500);
    let events = store.listEvents();
    if (module) events = events.filter((e) => e.module === module);
    if (name) events = events.filter((e) => e.name === name);
    // newest first
    events = [...events].sort((a, b) => (b.timestampMs ?? 0) - (a.timestampMs ?? 0));
    res.json({ total: events.length, events: events.slice(0, limit) });
  });

  // GET /claims?state=PAID
  app.get("/claims", (req, res) => {
    const { state } = req.query as { state?: string };
    let claims = store.listClaims();
    if (state) claims = claims.filter((c) => c.state === state);
    claims = [...claims].sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0));
    res.json({ total: claims.length, claims });
  });

  // GET /claims/:id  (full view + its event history)
  app.get("/claims/:id", (req, res) => {
    const claim = store.getClaim(req.params.id);
    if (!claim) return res.status(404).json({ error: "claim not found" });
    const events = store
      .listEvents()
      .filter((e) => e.parsedJson?.claim_id === req.params.id)
      .sort((a, b) => (a.timestampMs ?? 0) - (b.timestampMs ?? 0));
    return res.json({ claim, events });
  });

  // GET /stats
  app.get("/stats", (_req, res) => {
    const claims = store.listClaims();
    const byState: Record<string, number> = {};
    for (const c of claims) byState[c.state] = (byState[c.state] ?? 0) + 1;
    res.json({
      events: store.listEvents().length,
      claims: claims.length,
      claimsByState: byState,
      lastPollAt: store.meta().lastPollAt,
    });
  });

  return app;
}
