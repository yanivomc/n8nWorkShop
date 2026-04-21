"""
ClawOps Event Watcher — K8s API real-time event stream
Catches pod/deployment events before Prometheus sees them.
Admin UI at /  |  SSE stream at /events/stream  |  Config at /config
"""
import os, json, logging, sys, asyncio, sqlite3, httpx
from datetime import datetime, timezone
from typing import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from kubernetes import client as k8s_client, config as k8s_config, watch

# ── Config from env (populated by ConfigMap) ─────────────────────────────────
WATCH_NAMESPACES   = [n.strip() for n in os.getenv("WATCH_NAMESPACES", "workshop,clawops").split(",") if n.strip()]
WATCH_LABELS       = os.getenv("WATCH_LABELS", "")           # e.g. "app=target-app"
WATCH_REASONS      = [r.strip() for r in os.getenv("WATCH_REASONS",
    "OOMKilling,BackOff,Failed,Killing,Scheduled,Started,Pulled,Created,"
    "SuccessfulCreate,ScalingReplicaSet,FailedScheduling,Evicted,NodeNotReady"
).split(",") if r.strip()]
N8N_WEBHOOK_URL    = os.getenv("N8N_WEBHOOK_URL", "")        # blank = disabled
N8N_SERIOUS_REASONS = [r.strip() for r in os.getenv("N8N_SERIOUS_REASONS",
    "OOMKilling,BackOff,Failed,Killing,Evicted,FailedScheduling,NodeNotReady"
).split(",") if r.strip()]
DASHBOARD_SSE_URL  = os.getenv("DASHBOARD_SSE_URL", "")      # push to dashboard
DB_PATH            = os.getenv("DB_PATH", "/data/events.db")
MAX_STORED_EVENTS  = int(os.getenv("MAX_STORED_EVENTS", "500"))

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | event-watcher | %(message)s")
log = logging.getLogger("event-watcher")

# ── DB ────────────────────────────────────────────────────────────────────────
def get_db():
    os.makedirs(os.path.dirname(DB_PATH) if os.path.dirname(DB_PATH) else ".", exist_ok=True)
    c = sqlite3.connect(DB_PATH)
    c.row_factory = sqlite3.Row
    return c

def init_db():
    with get_db() as c:
        c.execute("""CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            namespace TEXT,
            kind TEXT,
            name TEXT,
            reason TEXT,
            message TEXT,
            severity TEXT,
            source TEXT,
            deploy TEXT,
            node TEXT
        )""")
        c.commit()
    log.info("DB ready")

# ── SSE subscribers ──────────────────────────────────────────────────────────
_subscribers: list[asyncio.Queue] = []

async def broadcast(event: dict):
    dead = []
    for q in _subscribers:
        try:
            q.put_nowait(event)
        except asyncio.QueueFull:
            dead.append(q)
    for d in dead:
        _subscribers.remove(d)

# ── Severity mapping ─────────────────────────────────────────────────────────
def get_severity(reason: str) -> str:
    if reason in {"OOMKilling","Evicted","FailedScheduling","NodeNotReady","BackOff"}:
        return "error"
    if reason in {"Failed","Killing","FailedMount","Unhealthy"}:
        return "warn"
    return "info"

# ── Extract deployment name from owner references ────────────────────────────
def extract_deploy(involved: k8s_client.V1ObjectReference, ns: str) -> str:
    name = involved.name or ""
    # strip random suffix heuristic: deployment-rs-pod → deployment
    parts = name.rsplit("-", 2)
    if len(parts) >= 3:
        return parts[0]
    if len(parts) == 2:
        return parts[0]
    return name

# ── Store event ───────────────────────────────────────────────────────────────
def store_event(ev: dict):
    with get_db() as c:
        c.execute("""INSERT INTO events (ts,namespace,kind,name,reason,message,severity,source,deploy,node)
            VALUES (:ts,:namespace,:kind,:name,:reason,:message,:severity,:source,:deploy,:node)""", ev)
        # trim old
        c.execute(f"DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT {MAX_STORED_EVENTS})")
        c.commit()

# ── Batch buffer — hold events per resource for N seconds then send summary ───
BATCH_WINDOW   = int(os.getenv("BATCH_WINDOW_SECONDS", "10"))
_batch: dict   = {}   # key → {"events": [], "task": asyncio.Task}

async def _flush_batch(key: str):
    """Wait BATCH_WINDOW seconds then send the buffered events as one payload."""
    await asyncio.sleep(BATCH_WINDOW)
    batch = _batch.pop(key, None)
    if not batch or not batch["events"]:
        return
    evs   = batch["events"]
    first = evs[0]
    # Build summary
    reasons   = list(dict.fromkeys(e["reason"] for e in evs))   # ordered unique
    messages  = [e["message"] for e in evs if e["message"]]
    severity  = "error" if any(e["severity"] == "error" for e in evs) else "warn"
    summary = {
        "source":    "k8s-event-watcher",
        "batched":   True,
        "count":     len(evs),
        "window_s":  BATCH_WINDOW,
        "severity":  severity,
        "namespace": first["namespace"],
        "kind":      first["kind"],
        "name":      first["name"],
        "deploy":    first["deploy"],
        "node":      first["node"],
        "reasons":   reasons,
        "reason":    reasons[0],              # primary reason for compat
        "message":   " | ".join(dict.fromkeys(messages))[:500],
        "events":    evs,
        "ts":        first["ts"],
    }
    log.info(f"BATCH FLUSH | {key} | {len(evs)} events | reasons: {reasons}")
    if N8N_WEBHOOK_URL:
        try:
            async with httpx.AsyncClient(timeout=10) as cli:
                await cli.post(N8N_WEBHOOK_URL, json=summary)
            log.info(f"Forwarded batch to n8n: {key}")
        except Exception as e:
            log.warning(f"n8n batch forward failed: {e}")

async def forward_to_n8n(ev: dict):
    """Buffer event into a batch keyed by namespace+name, flush after BATCH_WINDOW."""
    if not N8N_WEBHOOK_URL:
        return
    # Always buffer serious events; ignore pure info
    if ev.get("severity") == "info" and ev.get("reason") not in N8N_SERIOUS_REASONS:
        return
    # Group by deploy name (strips pod suffix) — batches entire deployment storm
    # Falls back to object name if no deploy detected
    group = ev.get("deploy") or ev.get("name", "unknown")
    # For node-level events, group by node
    if ev.get("kind") in ("Node", "NodeCondition"):
        group = ev.get("node") or ev.get("name", "unknown")
    key = f"{ev['namespace']}:{group}"
    loop = asyncio.get_event_loop()
    if key not in _batch:
        _batch[key] = {"events": [], "task": None}
    _batch[key]["events"].append(ev)
    # Cancel existing flush timer, restart it (extend window on new events up to 30s max)
    if _batch[key]["task"] and not _batch[key]["task"].done():
        elapsed = len(_batch[key]["events"])
        if elapsed < 20:  # keep extending up to ~20 events
            _batch[key]["task"].cancel()
            _batch[key]["task"] = asyncio.ensure_future(_flush_batch(key))
    else:
        _batch[key]["task"] = asyncio.ensure_future(_flush_batch(key))

# ── K8s event watcher (runs in thread) ───────────────────────────────────────
def watch_namespace(ns: str, loop: asyncio.AbstractEventLoop):
    v1 = k8s_client.CoreV1Api()
    w = watch.Watch()
    log.info(f"Watching namespace: {ns}")
    field_selector = f"involvedObject.namespace={ns}" if ns != "*" else ""
    try:
        for raw in w.stream(v1.list_namespaced_event, namespace=ns,
                            field_selector=field_selector if field_selector else None,
                            timeout_seconds=0):
            obj = raw["object"]
            reason = obj.reason or ""

            # filter by configured reasons
            if WATCH_REASONS and reason not in WATCH_REASONS:
                continue

            involved = obj.involved_object
            ev = {
                "ts":        datetime.now(timezone.utc).isoformat(),
                "namespace": obj.metadata.namespace or ns,
                "kind":      involved.kind or "Unknown",
                "name":      involved.name or "",
                "reason":    reason,
                "message":   (obj.message or "")[:300],
                "severity":  get_severity(reason),
                "source":    obj.source.component if obj.source else "",
                "deploy":    extract_deploy(involved, ns),
                "node":      obj.source.host if obj.source else "",
            }
            log.info(f"EVENT | {ev['namespace']} | {ev['severity'].upper()} | {ev['reason']} | {ev['name']}")
            store_event(ev)
            asyncio.run_coroutine_threadsafe(broadcast(ev), loop)
            asyncio.run_coroutine_threadsafe(forward_to_n8n(ev), loop)
    except Exception as e:
        log.error(f"Watch error ({ns}): {e}")

# ── App startup ───────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    try:
        k8s_config.load_incluster_config()
        log.info("K8s: in-cluster config")
    except:
        try:
            k8s_config.load_kube_config()
            log.info("K8s: kubeconfig")
        except Exception as e:
            log.error(f"K8s config failed: {e}")

    loop = asyncio.get_event_loop()
    import concurrent.futures
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=len(WATCH_NAMESPACES) + 1)
    for ns in WATCH_NAMESPACES:
        executor.submit(watch_namespace, ns, loop)
    log.info(f"Watching namespaces: {WATCH_NAMESPACES}")
    yield
    executor.shutdown(wait=False)

app = FastAPI(title="ClawOps Event Watcher", lifespan=lifespan)

# ── SSE stream ────────────────────────────────────────────────────────────────
async def event_generator(request: Request) -> AsyncGenerator[str, None]:
    q: asyncio.Queue = asyncio.Queue(maxsize=100)
    _subscribers.append(q)
    try:
        yield f"data: {json.dumps({'type':'connected','ts':datetime.now(timezone.utc).isoformat()})}\n\n"
        while True:
            if await request.is_disconnected():
                break
            try:
                ev = await asyncio.wait_for(q.get(), timeout=15)
                yield f"data: {json.dumps(ev)}\n\n"
            except asyncio.TimeoutError:
                yield ": keepalive\n\n"
    finally:
        if q in _subscribers:
            _subscribers.remove(q)

@app.get("/events/stream")
async def stream_events(request: Request):
    return StreamingResponse(event_generator(request),
        media_type="text/event-stream",
        headers={"Cache-Control":"no-cache","X-Accel-Buffering":"no"})

# ── REST endpoints ────────────────────────────────────────────────────────────
@app.get("/events")
def get_events(limit: int = 100, namespace: str = "", severity: str = "", reason: str = ""):
    with get_db() as c:
        q = "SELECT * FROM events WHERE 1=1"
        params = []
        if namespace: q += " AND namespace=?"; params.append(namespace)
        if severity:  q += " AND severity=?";  params.append(severity)
        if reason:    q += " AND reason=?";    params.append(reason)
        q += " ORDER BY id DESC LIMIT ?"
        params.append(limit)
        rows = c.execute(q, params).fetchall()
    return [dict(r) for r in rows]

@app.delete("/events")
def clear_events():
    with get_db() as c:
        c.execute("DELETE FROM events")
        c.commit()
    return {"cleared": True}

@app.get("/health")
def health():
    return {"status": "ok", "watching": WATCH_NAMESPACES, "n8n_configured": bool(N8N_WEBHOOK_URL)}

@app.get("/config")
def get_config():
    return {
        "watch_namespaces":    WATCH_NAMESPACES,
        "watch_labels":        WATCH_LABELS,
        "watch_reasons":       WATCH_REASONS,
        "n8n_webhook_url":     N8N_WEBHOOK_URL or "(not set)",
        "n8n_serious_reasons": N8N_SERIOUS_REASONS,
        "max_stored_events":   MAX_STORED_EVENTS,
        "batch_window_s":      BATCH_WINDOW,
        "cooldown_s":          COOLDOWN_S,
        "db_path":             DB_PATH,
    }

@app.get("/stats")
def get_stats():
    with get_db() as c:
        total   = c.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        errors  = c.execute("SELECT COUNT(*) FROM events WHERE severity='error'").fetchone()[0]
        warns   = c.execute("SELECT COUNT(*) FROM events WHERE severity='warn'").fetchone()[0]
        by_ns   = {r[0]:r[1] for r in c.execute("SELECT namespace,COUNT(*) FROM events GROUP BY namespace").fetchall()}
        by_rsn  = {r[0]:r[1] for r in c.execute("SELECT reason,COUNT(*) FROM events GROUP BY reason ORDER BY 2 DESC LIMIT 10").fetchall()}
    now = asyncio.get_event_loop().time()
    active_cooldowns = {k: int(COOLDOWN_S - (now - v)) for k, v in _cooldown.items() if (now - v) < COOLDOWN_S}
    return {"total": total, "errors": errors, "warns": warns, "by_namespace": by_ns, "by_reason": by_rsn, "subscribers": len(_subscribers), "active_cooldowns": active_cooldowns, "pending_batches": list(_batch.keys())}

# ── Admin UI ──────────────────────────────────────────────────────────────────
@app.get("/", response_class=HTMLResponse)
def admin_ui():
    config = get_config()
    return HTMLResponse(f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ClawOps Event Watcher</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#080C18;color:#e2e8f0;font-size:13px}}
header{{background:#0D1F3C;border-bottom:1px solid #1E3A5F;padding:14px 24px;display:flex;align-items:center;gap:16px}}
header h1{{font-size:16px;font-weight:600;color:#fff}}
.badge{{font-size:11px;padding:2px 10px;border-radius:999px;background:#0F6E56;color:#9FE1CB;font-weight:500;display:flex;align-items:center;gap:5px}}
.dot{{width:6px;height:6px;border-radius:50%;background:#00C896;animation:blink 1.4s infinite}}
@keyframes blink{{0%,100%{{opacity:1}}50%{{opacity:.3}}}}
.ml{{margin-left:auto}}
.stats{{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;padding:16px 24px}}
.stat{{background:#0F1729;border:1px solid #1E3A5F;border-radius:8px;padding:12px 16px}}
.sv{{font-size:26px;font-weight:600}}
.sl{{font-size:11px;color:#8892A4;margin-top:4px}}
.controls{{padding:0 24px 12px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}}
select,button{{font-size:12px;padding:5px 12px;border:1px solid #1E3A5F;border-radius:6px;background:#0D1F3C;color:#e2e8f0;cursor:pointer}}
button:hover{{background:#1E3A5F}}
button.danger{{border-color:#A32D2D;color:#F09595}}
button.danger:hover{{background:#A32D2D;color:#fff}}
.config-section{{margin:0 24px 16px;background:#0F1729;border:1px solid #1E3A5F;border-radius:8px;padding:12px 16px}}
.config-title{{font-size:11px;color:#8892A4;margin-bottom:8px;font-weight:600;letter-spacing:.05em;text-transform:uppercase}}
.config-grid{{display:grid;grid-template-columns:repeat(2,1fr);gap:6px}}
.cfg{{font-size:11px;color:#8892A4}}.cfg span{{color:#00D4FF;font-family:monospace}}
table{{width:calc(100% - 48px);margin:0 24px;border-collapse:collapse;font-size:12px}}
th{{background:#0D1F3C;color:#8892A4;text-align:left;padding:7px 10px;font-weight:500;border-bottom:1px solid #1E3A5F;font-size:11px;text-transform:uppercase;letter-spacing:.05em}}
td{{padding:7px 10px;border-bottom:1px solid #1E3A5F;vertical-align:top}}
tr:hover td{{background:#0F1729}}
.sev-error{{color:#F09595}}.sev-warn{{color:#EF9F27}}.sev-info{{color:#9FE1CB}}
.reason{{font-family:monospace;background:#0D1F3C;padding:1px 6px;border-radius:4px;font-size:10px}}
.empty{{text-align:center;color:#8892A4;padding:40px;font-size:14px}}
.ns-badge{{font-size:9px;padding:1px 6px;border-radius:999px;background:#1E3A5F;color:#8892A4}}
.search{{padding:5px 12px;border:1px solid #1E3A5F;border-radius:6px;background:#0D1F3C;color:#e2e8f0;width:200px}}
</style>
</head>
<body>
<header>
  <h1>ClawOps Event Watcher</h1>
  <div class="badge"><div class="dot"></div><span id="status-text">connecting...</span></div>
  <div class="ml" style="display:flex;gap:8px;align-items:center">
    <span style="font-size:11px;color:#8892A4">watching:</span>
    {"".join(f'<span class="ns-badge">{ns}</span>' for ns in config["watch_namespaces"])}
  </div>
</header>

<div class="stats" id="stats">
  <div class="stat"><div class="sv" id="s-total">—</div><div class="sl">total events</div></div>
  <div class="stat"><div class="sv sev-error" id="s-errors">—</div><div class="sl">errors</div></div>
  <div class="stat"><div class="sv sev-warn" id="s-warns">—</div><div class="sl">warnings</div></div>
  <div class="stat"><div class="sv" style="color:#00D4FF" id="s-subs">—</div><div class="sl">SSE subscribers</div></div>
</div>

<div class="config-section">
  <div class="config-title">configuration</div>
  <div class="config-grid">
    <div class="cfg">namespaces: <span>{', '.join(config['watch_namespaces'])}</span></div>
    <div class="cfg">n8n webhook: <span>{config['n8n_webhook_url']}</span></div>
    <div class="cfg">serious reasons (→n8n): <span>{', '.join(config['n8n_serious_reasons'])}</span></div>
    <div class="cfg">max stored: <span>{config['max_stored_events']}</span></div>
  </div>
</div>

<div class="controls">
  <input class="search" type="text" id="search" placeholder="search events..." oninput="filterTable()">
  <select id="ns-filter" onchange="loadEvents()"><option value="">all namespaces</option>{"".join(f'<option value="{ns}">{ns}</option>' for ns in config["watch_namespaces"])}</select>
  <select id="sev-filter" onchange="loadEvents()">
    <option value="">all severities</option>
    <option value="error">errors</option>
    <option value="warn">warnings</option>
    <option value="info">info</option>
  </select>
  <select id="limit-filter" onchange="loadEvents()">
    <option value="50">last 50</option>
    <option value="100" selected>last 100</option>
    <option value="250">last 250</option>
  </select>
  <button onclick="loadEvents()">refresh</button>
  <button class="danger" onclick="clearEvents()">clear all</button>
  <span id="live-indicator" style="font-size:11px;color:#8892A4;margin-left:4px"></span>
</div>

<table>
<thead><tr>
  <th style="width:140px">time</th>
  <th style="width:90px">severity</th>
  <th style="width:80px">namespace</th>
  <th style="width:120px">deployment</th>
  <th style="width:180px">object</th>
  <th style="width:100px">reason</th>
  <th>message</th>
</tr></thead>
<tbody id="tbody"></tbody>
</table>

<script>
let allEvents = [];

function sevClass(s){{return 'sev-'+s}}
function sevIcon(s){{return s==='error'?'✕':s==='warn'?'⚠':'✓'}}

function renderRow(e, prepend=false){{
  const tr = document.createElement('tr');
  tr.innerHTML = `
    <td style="font-family:monospace;font-size:11px;color:#8892A4">${{e.ts.replace('T',' ').substring(0,19)}}</td>
    <td class="${{sevClass(e.severity)}}">${{sevIcon(e.severity)}} ${{e.severity}}</td>
    <td><span class="ns-badge">${{e.namespace||''}}</span></td>
    <td style="color:#00D4FF;font-family:monospace;font-size:11px">${{e.deploy||'—'}}</td>
    <td style="font-family:monospace;font-size:11px;color:#8892A4">${{(e.name||'').split('-').slice(-2).join('-')||e.name}}<br><span style="color:#534AB7;font-size:9px">${{e.kind||''}}</span></td>
    <td><span class="reason">${{e.reason||''}}</span></td>
    <td style="color:#e2e8f0;max-width:300px;word-break:break-word">${{e.message||''}}</td>
  `;
  if (prepend) tr.style.animation = 'none';
  return tr;
}}

function loadEvents(){{
  const ns = document.getElementById('ns-filter').value;
  const sev = document.getElementById('sev-filter').value;
  const limit = document.getElementById('limit-filter').value;
  let url = `events?limit=${{limit}}`;
  if (ns) url += `&namespace=${{ns}}`;
  if (sev) url += `&severity=${{sev}}`;
  fetch(url).then(r=>r.json()).then(data=>{{
    allEvents = data;
    renderTable(data);
  }});
}}

function renderTable(data){{
  const tb = document.getElementById('tbody');
  if (!data.length) {{ tb.innerHTML = '<tr><td colspan="7" class="empty">No events yet — waiting for K8s activity</td></tr>'; return; }}
  tb.innerHTML = '';
  data.forEach(e => tb.appendChild(renderRow(e)));
}}

function filterTable(){{
  const q = document.getElementById('search').value.toLowerCase();
  const filtered = allEvents.filter(e => JSON.stringify(e).toLowerCase().includes(q));
  renderTable(filtered);
}}

function clearEvents(){{
  if (!confirm('Clear all stored events?')) return;
  fetch('events',{{method:'DELETE'}}).then(()=>{{ allEvents=[]; loadEvents(); loadStats(); }});
}}

function loadStats(){{
  fetch('stats').then(r=>r.json()).then(s=>{{
    document.getElementById('s-total').textContent = s.total;
    document.getElementById('s-errors').textContent = s.errors;
    document.getElementById('s-warns').textContent = s.warns;
    document.getElementById('s-subs').textContent = s.subscribers;
  }});
}}

// SSE live updates
const es = new EventSource('events/stream');
es.onopen = ()=>{{
  document.getElementById('status-text').textContent = 'live';
  document.getElementById('live-indicator').textContent = '';
}};
es.onerror = ()=>{{
  document.getElementById('status-text').textContent = 'reconnecting...';
}};
es.onmessage = (e)=>{{
  const data = JSON.parse(e.data);
  if (data.type === 'connected') return;
  document.getElementById('live-indicator').textContent = `↑ new event: ${{data.reason}} on ${{data.name}}`;
  setTimeout(()=>document.getElementById('live-indicator').textContent='', 4000);
  allEvents.unshift(data);
  loadEvents();
  loadStats();
}};

// initial load
loadEvents();
loadStats();
setInterval(loadStats, 10000);
</script>
</body>
</html>""")
