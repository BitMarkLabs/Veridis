/**
 * Self-contained dashboard for the Veridis indexer.
 * Served at GET / from the same origin as the API, so it reads the
 * /health, /stats, /claims and /events endpoints with no CORS setup.
 */
export const DASHBOARD_HTML = /* html */ `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Veridis — Claims Portal</title>
<style>
  :root {
    --bg:#0b0f17; --panel:#131a26; --panel2:#0f1521; --line:#1f2a3a;
    --text:#e6edf6; --muted:#8a99b0; --accent:#5b9dff; --good:#36d399;
    --warn:#fbbf24; --bad:#f87171; --chip:#1b2536;
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
    font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif; }
  header { padding:18px 24px; border-bottom:1px solid var(--line);
    display:flex; align-items:center; gap:16px; flex-wrap:wrap; }
  .brand { font-size:18px; font-weight:700; letter-spacing:.3px; }
  .brand span { color:var(--accent); }
  .dot { width:9px; height:9px; border-radius:50%; background:var(--bad);
    display:inline-block; margin-right:6px; }
  .dot.ok { background:var(--good); box-shadow:0 0 8px var(--good); }
  .muted { color:var(--muted); }
  .pkg { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12px;
    background:var(--chip); padding:4px 8px; border-radius:6px; color:var(--muted); }
  main { padding:24px; max-width:1200px; margin:0 auto; }
  .cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr));
    gap:14px; margin-bottom:24px; }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:12px;
    padding:16px 18px; }
  .card .label { color:var(--muted); font-size:12px; text-transform:uppercase;
    letter-spacing:.6px; }
  .card .value { font-size:30px; font-weight:700; margin-top:4px; }
  .states { display:flex; gap:8px; flex-wrap:wrap; margin-top:8px; }
  .chip { background:var(--chip); border:1px solid var(--line); border-radius:999px;
    padding:3px 10px; font-size:12px; }
  .chip b { color:var(--accent); }
  h2 { font-size:15px; margin:24px 0 12px; font-weight:600; }
  .grid2 { display:grid; grid-template-columns:1fr 1fr; gap:24px; }
  @media (max-width:880px){ .grid2{ grid-template-columns:1fr; } }
  table { width:100%; border-collapse:collapse; background:var(--panel);
    border:1px solid var(--line); border-radius:12px; overflow:hidden; }
  th,td { text-align:left; padding:10px 12px; border-bottom:1px solid var(--line);
    font-size:13px; }
  th { color:var(--muted); font-weight:600; font-size:11px; text-transform:uppercase;
    letter-spacing:.5px; background:var(--panel2); }
  tr:last-child td { border-bottom:none; }
  tr.click { cursor:pointer; }
  tr.click:hover { background:#172132; }
  .mono { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12px; }
  .pill { padding:2px 9px; border-radius:999px; font-size:11px; font-weight:600;
    display:inline-block; }
  .s-PAID { background:rgba(54,211,153,.15); color:var(--good); }
  .s-APPROVED { background:rgba(91,157,255,.15); color:var(--accent); }
  .s-SUBMITTED,.s-UNDER_REVIEW,.s-ASSESSED { background:rgba(251,191,36,.15); color:var(--warn); }
  .s-REJECTED,.s-DISPUTED { background:rgba(248,113,113,.15); color:var(--bad); }
  .ev { font-size:12px; }
  footer { color:var(--muted); font-size:12px; padding:16px 24px; text-align:center; }
  dialog { background:var(--panel); color:var(--text); border:1px solid var(--line);
    border-radius:14px; padding:0; max-width:680px; width:92%; }
  dialog::backdrop { background:rgba(0,0,0,.6); }
  .dlg-head { padding:16px 20px; border-bottom:1px solid var(--line);
    display:flex; justify-content:space-between; align-items:center; }
  .dlg-body { padding:16px 20px; max-height:60vh; overflow:auto; }
  .x { cursor:pointer; color:var(--muted); font-size:20px; background:none;
    border:none; }
  .timeline { list-style:none; padding:0; margin:0; }
  .timeline li { padding:8px 0 8px 18px; border-left:2px solid var(--line);
    position:relative; }
  .timeline li::before { content:""; position:absolute; left:-6px; top:13px;
    width:9px; height:9px; border-radius:50%; background:var(--accent); }
  a { color:var(--accent); text-decoration:none; }
</style>
</head>
<body>
<header>
  <div class="brand">Veridis<span>·</span>Claims Portal</div>
  <div><span id="dot" class="dot"></span><span id="status" class="muted">connecting…</span></div>
  <div style="flex:1"></div>
  <div id="pkg" class="pkg">package: —</div>
</header>

<main>
  <div class="cards">
    <div class="card"><div class="label">Total events</div><div id="c-events" class="value">—</div></div>
    <div class="card"><div class="label">Total claims</div><div id="c-claims" class="value">—</div></div>
    <div class="card" style="grid-column:span 2">
      <div class="label">Claims by state</div>
      <div id="c-states" class="states"></div>
    </div>
    <div class="card"><div class="label">Last poll</div><div id="c-poll" class="value" style="font-size:16px">—</div></div>
  </div>

  <div class="grid2">
    <div>
      <h2>Claims <span class="muted" id="claims-n"></span></h2>
      <table>
        <thead><tr><th>Claim</th><th>State</th><th>Amount</th><th>Updated</th></tr></thead>
        <tbody id="claims-body"><tr><td colspan="4" class="muted">loading…</td></tr></tbody>
      </table>
    </div>
    <div>
      <h2>Recent events <span class="muted" id="events-n"></span></h2>
      <table>
        <thead><tr><th>Module</th><th>Event</th><th>When</th></tr></thead>
        <tbody id="events-body"><tr><td colspan="3" class="muted">loading…</td></tr></tbody>
      </table>
    </div>
  </div>
</main>

<footer>Auto-refreshing every 4s · read-only view of on-chain Veridis events</footer>

<dialog id="dlg">
  <div class="dlg-head">
    <div><b>Claim</b> <span id="dlg-id" class="mono"></span></div>
    <button class="x" onclick="document.getElementById('dlg').close()">×</button>
  </div>
  <div class="dlg-body">
    <div id="dlg-meta" class="muted" style="margin-bottom:14px"></div>
    <ul id="dlg-timeline" class="timeline"></ul>
  </div>
</dialog>

<script>
const $ = (id) => document.getElementById(id);
const short = (s) => s ? s.slice(0,8) + "…" + s.slice(-6) : "—";
const ago = (ms) => {
  if (!ms) return "—";
  const s = Math.round((Date.now()-ms)/1000);
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.round(s/60) + "m ago";
  return Math.round(s/3600) + "h ago";
};
const pill = (st) => '<span class="pill s-'+st+'">'+st+'</span>';

async function j(path){ const r = await fetch(path); if(!r.ok) throw new Error(path); return r.json(); }

async function refresh(){
  try {
    const [h, stats, claims, events] = await Promise.all([
      j('/health'), j('/stats'), j('/claims'), j('/events?limit=12')
    ]);
    $('dot').classList.add('ok');
    $('status').textContent = h.packageConfigured ? 'live · testnet' : 'idle · package not set';
    $('pkg').textContent = 'package: ' + short(h.packageId);
    $('c-events').textContent = stats.events;
    $('c-claims').textContent = stats.claims;
    $('c-poll').textContent = ago(stats.lastPollAt);
    $('c-states').innerHTML = Object.keys(stats.claimsByState).length
      ? Object.entries(stats.claimsByState).map(([s,n]) => '<span class="chip">'+s+' <b>'+n+'</b></span>').join('')
      : '<span class="muted">none yet</span>';

    $('claims-n').textContent = '('+claims.total+')';
    $('claims-body').innerHTML = claims.claims.length ? claims.claims.map(c =>
      '<tr class="click" onclick="openClaim(\\''+c.claimId+'\\')">'+
        '<td class="mono">'+short(c.claimId)+'</td>'+
        '<td>'+pill(c.state)+'</td>'+
        '<td class="mono">'+(c.amount ?? '—')+'</td>'+
        '<td class="muted">'+ago(c.updatedAt)+'</td></tr>'
    ).join('') : '<tr><td colspan="4" class="muted">no claims indexed yet</td></tr>';

    $('events-n').textContent = '('+events.total+')';
    $('events-body').innerHTML = events.events.length ? events.events.map(e =>
      '<tr><td class="mono">'+e.module+'</td><td class="ev">'+e.name+'</td>'+
      '<td class="muted">'+ago(e.timestampMs)+'</td></tr>'
    ).join('') : '<tr><td colspan="3" class="muted">no events yet</td></tr>';
  } catch (err) {
    $('dot').classList.remove('ok');
    $('status').textContent = 'disconnected';
  }
}

async function openClaim(id){
  const dlg = $('dlg');
  $('dlg-id').textContent = short(id);
  $('dlg-meta').textContent = 'loading…';
  $('dlg-timeline').innerHTML = '';
  dlg.showModal();
  try {
    const { claim, events } = await j('/claims/'+id);
    $('dlg-meta').innerHTML = pill(claim.state) +
      ' &nbsp; amount: <b>'+(claim.amount ?? '—')+'</b>' +
      (claim.payee ? ' &nbsp; payee: <span class="mono">'+short(claim.payee)+'</span>' : '');
    $('dlg-timeline').innerHTML = events.map(e =>
      '<li><b>'+e.name+'</b> <span class="muted">· '+e.module+' · '+ago(e.timestampMs)+'</span></li>'
    ).join('') || '<li class="muted">no event history</li>';
  } catch { $('dlg-meta').textContent = 'failed to load claim'; }
}

refresh();
setInterval(refresh, 4000);
</script>
</body>
</html>`;
