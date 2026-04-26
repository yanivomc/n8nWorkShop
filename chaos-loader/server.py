"""
Chaos Loader — sidecar container that pounds target-app via localhost.
Survives target-app restarts, keeps hammering the fresh container.
API: POST /start?mode=oom|cpu|error  POST /stop  GET /status
"""
import asyncio, httpx, time, os
from fastapi import FastAPI
from fastapi.responses import JSONResponse

TARGET = os.getenv("TARGET_URL", "http://localhost:8080")
app = FastAPI()

state = {"running": False, "mode": None, "hits": 0, "errors": 0, "started_at": None}
_task = None

async def _loop(mode: str):
    state["running"] = True
    state["hits"] = 0
    state["errors"] = 0
    state["started_at"] = time.time()
    print(f"[chaos-loader] starting loop mode={mode}")
    while state["running"]:
        try:
            async with httpx.AsyncClient(timeout=5) as c:
                if mode == "oom":
                    await c.post(f"{TARGET}/chaos/error-loop", json={})
                elif mode == "cpu":
                    await c.post(f"{TARGET}/chaos/cpu", json={"cores": 2, "duration_seconds": 60})
                elif mode == "error":
                    await c.post(f"{TARGET}/chaos/error-loop", json={})
            state["hits"] += 1
            print(f"[chaos-loader] hit #{state['hits']} mode={mode}")
        except Exception as e:
            state["errors"] += 1
            print(f"[chaos-loader] error (target restarting?): {e}")
        # Wait before next hit — target-app may be restarting
        await asyncio.sleep(15)

@app.post("/start")
async def start(mode: str = "oom"):
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
    if _task: _task.cancel()
    # Also stop chaos on target-app
    try:
        async with httpx.AsyncClient(timeout=3) as c:
            await c.delete(f"{TARGET}/chaos/all")
    except: pass
    return {"status": "stopped", "hits": state["hits"], "errors": state["errors"]}

@app.get("/status")
async def status():
    uptime = round(time.time() - state["started_at"]) if state["started_at"] and state["running"] else 0
    return {**state, "uptime_s": uptime, "target": TARGET}

@app.get("/health")
async def health():
    return {"status": "ok"}
