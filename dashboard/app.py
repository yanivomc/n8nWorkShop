import os, time, logging, sys, asyncio
import httpx
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

logging.basicConfig(stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | dashboard | %(message)s")
logger = logging.getLogger("dashboard")

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

_instances: dict = {}

class RegisterPayload(BaseModel):
    app: str = "target-app"
    version: str = "1.0.0"
    namespace: str = "default"
    pod: str = "unknown"
    port: int = 8080

@app.post("/api/register")
async def register(payload: RegisterPayload):
    try:
        inst_id = f"{payload.namespace}/{payload.pod}"
        internal_url = f"http://{payload.app}.{payload.namespace}.svc.cluster.local:{payload.port}"
        _instances[inst_id] = {
            "id": inst_id,
            "app": payload.app,
            "version": payload.version,
            "namespace": payload.namespace,
            "pod": payload.pod,
            "url": internal_url,
            "chaos": {},
            "alive": False,
            "registered_at": time.time(),
        }
        logger.info(f"REGISTERED | {inst_id} | {internal_url}")
        return {"status": "registered", "id": inst_id}
    except Exception as e:
        logger.error(f"Register error: {e}")
        return JSONResponse({"status": "error", "detail": str(e)}, status_code=500)

@app.get("/api/instances")
async def get_instances():
    return {"instances": list(_instances.values()), "count": len(_instances)}

@app.post("/api/chaos/{inst_id:path}")
async def trigger_chaos(inst_id: str, request: dict):
    """Proxy chaos commands server-side to target-app internal URL."""
    inst = _instances.get(inst_id)
    if not inst:
        return JSONResponse({"error": "instance not found"}, status_code=404)
    try:
        chaos_type = request.get("type")
        method = request.get("method", "POST")
        body = request.get("body", {})
        url = f"{inst['url']}/chaos/{chaos_type}"
        async with httpx.AsyncClient(timeout=10) as client:
            if method == "DELETE":
                r = await client.delete(url)
            else:
                r = await client.post(url, json=body)
        logger.info(f"CHAOS | {inst_id} | {chaos_type} | status={r.status_code}")
        return r.json()
    except Exception as e:
        logger.error(f"Chaos proxy error: {e}")
        return JSONResponse({"status": "error", "detail": str(e)}, status_code=500)

@app.delete("/api/instances/{inst_id:path}")
async def remove_instance(inst_id: str):
    if inst_id in _instances:
        del _instances[inst_id]
        logger.info(f"REMOVED | {inst_id}")
        return {"status": "removed"}
    return JSONResponse({"status": "not_found"}, status_code=404)

@app.get("/api/health")
async def health():
    return {"status": "ok", "instances": len(_instances)}

@app.get("/config.js")
async def config_js():
    js = f"""window.CLAWOPS_CONFIG = {{
  prom:    "{os.getenv('PROMETHEUS_URL', 'http://localhost:9090')}",
  grafana: "{os.getenv('GRAFANA_URL', 'http://localhost:3000')}",
  am:      "{os.getenv('ALERTMANAGER_URL', 'http://localhost:9093')}",
  n8n:     "{os.getenv('N8N_URL', 'http://localhost:5678')}",
}};"""
    return Response(content=js, media_type="application/javascript")

async def poll_instances():
    """Background task — polls /chaos/status server-side via internal K8s DNS."""
    while True:
        for inst_id, inst in list(_instances.items()):
            try:
                async with httpx.AsyncClient(timeout=3) as client:
                    r = await client.get(f"{inst['url']}/chaos/status")
                    if r.status_code == 200:
                        data = r.json()
                        inst["chaos"] = {
                            "cpu": data.get("cpu_active", False),
                            "memory": data.get("memory_active", False),
                            "memMb": data.get("memory_current_mb", 0),
                        }
                        inst["alive"] = True
                    else:
                        inst["alive"] = False
            except Exception:
                inst["alive"] = False
        await asyncio.sleep(5)

@app.on_event("startup")
async def startup():
    asyncio.create_task(poll_instances())
    logger.info("Background instance poller started")

app.mount("/", StaticFiles(directory="/app/static", html=True), name="static")
