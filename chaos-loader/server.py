"""
Chaos Loader — sidecar container.
1. Registers target-app with dashboard (survives target-app restarts)
2. Pounds target-app with chaos when triggered
3. Exposes /logs so n8n AI can fetch recent failure context
"""
import asyncio, httpx, time, os, collections
from fastapi import FastAPI
from fastapi.responses import JSONResponse

TARGET      = os.getenv("TARGET_URL", "http://localhost:8080")
DASHBOARD   = os.getenv("DASHBOARD_URL", "")
APP_NAME    = os.getenv("APP_NAME", "target-app")
APP_VERSION = os.getenv("APP_VERSION", "1.0.0")
NAMESPACE   = os.getenv("POD_NAMESPACE", "workshop")
POD_NAME    = os.getenv("POD_NAME", "target-app")
PORT        = int(os.getenv("TARGET_PORT", "8080"))

app = FastAPI()

state   = {"running": False, "mode": None, "hits": 0, "errors": 0, "started_at": None}
_task   = None
# Ring buffer — last 50 log entries for n8n AI to inspect
_logs: collections.deque = collections.deque(maxlen=50)

def log(msg: str):
    entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "msg": msg}
    _logs.append(entry)
    print(f"[chaos-loader] {msg}")


# ── Registration loop (runs forever, survives target-app restarts) ────────────
async def registration_loop():
    if not DASHBOARD:
        log("No DASHBOARD_URL — skipping registration")
        return
    payload = {"app": APP_NAME, "version": APP_VERSION, "namespace": NAMESPACE,
               "pod": POD_NAME, "port": PORT}
    registered = False
    while True:
        try:
            async with httpx.AsyncClient(timeout=5) as c:
                r = await c.post(f"{DASHBOARD}/api/register", json=payload)
            if r.status_code == 200:
                if not registered:
                    log(f"REGISTERED with dashboard as {POD_NAME}")
                    registered = True
            else:
                registered = False
                log(f"Registration failed: {r.status_code}")
        except Exception as e:
            registered = False
            log(f"Dashboard unreachable: {e}")
        await asyncio.sleep(20)


# ── Chaos loop ────────────────────────────────────────────────────────────────
async def _loop(mode: str):
    state.update({"running": True, "hits": 0, "errors": 0, "started_at": time.time()})
    log(f"Chaos loop started | mode={mode} | target={TARGET}")
    while state["running"]:
        try:
            async with httpx.AsyncClient(timeout=5) as c:
                if mode == "error":
                    r = await c.post(f"{TARGET}/chaos/error-loop", json={})
                    log(f"Hit #{state['hits']+1} — error-loop triggered → /health will return 500 (K8s liveness will fail in ~45s)")
                elif mode == "oom":
                    r = await c.post(f"{TARGET}/chaos/memory", json={"mb_per_second": 50, "max_mb": 400})
                    log(f"Hit #{state['hits']+1} — memory leak triggered → OOMKill expected in ~8s")
                elif mode == "cpu":
                    r = await c.post(f"{TARGET}/chaos/cpu", json={"cores": 2, "duration_seconds": 60})
                    log(f"Hit #{state['hits']+1} — CPU spike triggered")
            state["hits"] += 1
        except Exception as e:
            state["errors"] += 1
            log(f"Target unreachable (restarting?) — error: {e} | will retry in 15s")
        await asyncio.sleep(15)
    log("Chaos loop stopped")


@app.on_event("startup")
async def startup():
    asyncio.create_task(registration_loop())
    log("Chaos-loader started — registration loop running")


@app.post("/start")
async def start(mode: str = "error"):
    global _task
    if state["running"]:
        return {"status": "already running", "mode": state["mode"]}
    state["mode"] = mode
    _task = asyncio.create_task(_loop(mode))
    return {"status": "started", "mode": mode, "target": TARGET}


@app.post("/stop")
async def stop():
    global _task
    state["running"] = False
    if _task:
        _task.cancel()
    # Stop chaos on target-app too
    try:
        async with httpx.AsyncClient(timeout=3) as c:
            await c.delete(f"{TARGET}/chaos/all")
        log("Chaos stopped — sent /chaos/all DELETE to target-app")
    except Exception as e:
        log(f"Could not reach target-app to stop chaos: {e}")
    return {"status": "stopped", "hits": state["hits"], "errors": state["errors"]}


@app.get("/status")
async def status():
    uptime = round(time.time() - state["started_at"]) if state["started_at"] and state["running"] else 0
    return {**state, "uptime_s": uptime, "target": TARGET, "pod": POD_NAME}


@app.get("/logs")
async def get_logs():
    """Recent chaos activity log — used by n8n AI to understand what's happening."""
    return {
        "pod": POD_NAME,
        "namespace": NAMESPACE,
        "chaos_active": state["running"],
        "chaos_mode": state["mode"],
        "hits": state["hits"],
        "errors": state["errors"],
        "recent_logs": list(_logs),
        "summary": (
            f"Chaos mode '{state['mode']}' has been running for "
            f"{round(time.time()-state['started_at'])}s with {state['hits']} hits "
            f"and {state['errors']} errors (target unreachable = pod restarting)"
        ) if state["running"] else "No chaos currently active"
    }


@app.get("/health")
async def health():
    return {"status": "ok", "pod": POD_NAME}
