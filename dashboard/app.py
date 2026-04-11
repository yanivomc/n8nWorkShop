import os, time, logging, sys, asyncio
import httpx
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel
from contextlib import asynccontextmanager

logging.basicConfig(stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | dashboard | %(message)s")
logger = logging.getLogger("dashboard")

_instances: dict = {}
DEAD_THRESHOLD = 3  # remove after this many consecutive failures

async def poll_chaos_status():
    while True:
        for inst_id in list(_instances.keys()):
            inst = _instances.get(inst_id)
            if not inst:
                continue
            try:
                async with httpx.AsyncClient(timeout=3) as client:
                    r = await client.get(f"{inst['internal_url']}/chaos/status")
                inst["chaos"] = r.json()
                inst["alive"] = True
                inst["fail_count"] = 0
            except Exception:
                inst["fail_count"] = inst.get("fail_count", 0) + 1
                inst["alive"] = False
                if inst["fail_count"] >= DEAD_THRESHOLD:
                    logger.warning(f"REMOVING dead instance | {inst_id} | fails={inst['fail_count']}")
                    _instances.pop(inst_id, None)
        await asyncio.sleep(5)

@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(poll_chaos_status())
    yield
    task.cancel()

app = FastAPI(lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

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
            "internal_url": internal_url,
            "chaos": {},
            "alive": True,
            "fail_count": 0,
            "registered_at": time.time(),
        }
        logger.info(f"REGISTERED | {inst_id} | {internal_url}")
        return {"status": "registered", "id": inst_id}
    except Exception as e:
        logger.error(f"Register error: {e}")
        return JSONResponse({"status": "error", "detail": str(e)}, status_code=500)

@app.get("/api/instances")
async def get_instances():
    result = [{
        "id": i["id"], "app": i["app"], "version": i["version"],
        "namespace": i["namespace"], "pod": i["pod"],
        "chaos": i.get("chaos", {}), "alive": i.get("alive", True),
        "registered_at": i["registered_at"],
    } for i in _instances.values()]
    return {"instances": result, "count": len(result)}

@app.post("/api/chaos/{inst_id:path}/action/{scenario}")
async def trigger_chaos(inst_id: str, scenario: str, request: Request):
    inst = _instances.get(inst_id)
    if not inst:
        return JSONResponse({"error": "instance not found"}, status_code=404)
    try:
        body = {}
        try:
            body = await request.json()
        except Exception:
            pass
        async with httpx.AsyncClient(timeout=10) as client:
            if request.method == "DELETE":
                r = await client.delete(f"{inst['internal_url']}/chaos/{scenario}")
            else:
                r = await client.post(f"{inst['internal_url']}/chaos/{scenario}", json=body)
        logger.info(f"CHAOS | {inst_id} | {scenario} | {r.status_code}")
        return r.json()
    except Exception as e:
        logger.error(f"Chaos proxy error: {e}")
        return JSONResponse({"error": str(e)}, status_code=500)

@app.delete("/api/chaos/{inst_id:path}/action/{scenario}")
async def trigger_chaos_delete(inst_id: str, scenario: str, request: Request):
    return await trigger_chaos(inst_id, scenario, request)

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

app.mount("/", StaticFiles(directory="/app/static", html=True), name="static")
