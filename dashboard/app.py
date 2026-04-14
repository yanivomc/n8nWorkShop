import os, time, logging, sys, asyncio
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel
from contextlib import asynccontextmanager

logging.basicConfig(stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | dashboard | %(message)s")
logger = logging.getLogger("dashboard")

_instances: dict = {}
_client: httpx.AsyncClient = None
DEAD_THRESHOLD = 3

async def poll_chaos_status():
    while True:
        for inst_id in list(_instances.keys()):
            inst = _instances.get(inst_id)
            if not inst:
                continue
            try:
                r = await _client.get(f"{inst['internal_url']}/chaos/status", timeout=3)
                inst["chaos"] = r.json()
                inst["alive"] = True
                inst["fail_count"] = 0
            except Exception as e:
                inst["fail_count"] = inst.get("fail_count", 0) + 1
                inst["alive"] = False
                logger.warning(f"POLL FAIL | {inst_id} | attempt {inst['fail_count']}/{DEAD_THRESHOLD} | {e}")
                if inst["fail_count"] >= DEAD_THRESHOLD:
                    logger.warning(f"REMOVING dead instance | {inst_id}")
                    _instances.pop(inst_id, None)
        await asyncio.sleep(5)

@asynccontextmanager
async def lifespan(app: FastAPI):
    global _client
    _client = httpx.AsyncClient(timeout=10.0)
    task = asyncio.create_task(poll_chaos_status())
    yield
    task.cancel()
    await _client.aclose()

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
            "id": inst_id, "app": payload.app, "version": payload.version,
            "namespace": payload.namespace, "pod": payload.pod,
            "internal_url": internal_url, "chaos": {}, "alive": True,
            "fail_count": 0, "registered_at": time.time(),
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

@app.api_route("/api/chaos/{inst_id:path}/action/{scenario}", methods=["POST", "DELETE"])
async def trigger_chaos(inst_id: str, scenario: str, request: Request):
    from urllib.parse import unquote
    inst_id = unquote(inst_id)
    inst = _instances.get(inst_id)
    if not inst:
        logger.error(f"CHAOS | instance not found: {inst_id} | known: {list(_instances.keys())}")
        return JSONResponse({"error": "instance not found"}, status_code=404)
    try:
        body = {}
        try:
            body = await request.json()
        except Exception:
            pass
        target = f"{inst['internal_url']}/chaos/{scenario}"
        logger.info(f"CHAOS PROXY | {request.method} {target} | body={body}")
        if request.method == "DELETE":
            r = await _client.delete(target)
        else:
            r = await _client.post(target, json=body)
        logger.info(f"CHAOS RESULT | {r.status_code}")
        return r.json()
    except Exception as e:
        logger.error(f"Chaos proxy error: {e}")
        return JSONResponse({"error": str(e)}, status_code=500)

@app.delete("/api/instances/{inst_id:path}")
async def remove_instance(inst_id: str):
    if inst_id in _instances:
        del _instances[inst_id]
        logger.info(f"REMOVED | {inst_id}")
        return {"status": "removed"}
    return JSONResponse({"status": "not_found"}, status_code=404)

@app.get("/api/incidents")
async def proxy_incidents(limit: int = 20):
    """Proxy incidents list from MCP server."""
    try:
        r = await _client.get(f"{MCP_URL}/incidents?limit={limit}")
        return r.json()
    except Exception as e:
        return {"incidents": [], "count": 0, "error": str(e)}

@app.delete("/api/incidents")
async def delete_all_incidents():
    """Proxy DELETE all incidents to MCP server."""
    try:
        r = await _client.delete(f"{MCP_URL}/incidents")
        return r.json()
    except Exception as e:
        return {"deleted": False, "error": str(e)}

@app.get("/api/health")
async def health():
    return {"status": "ok", "instances": len(_instances)}

@app.get("/config.js")
async def config_js():
    base_path = os.getenv('DASHBOARD_BASE_PATH', '').rstrip('/')
    js = f"""window.CLAWOPS_CONFIG = {{
  prom:     "{os.getenv('PROMETHEUS_URL', 'http://localhost:9090')}",
  grafana:  "{os.getenv('GRAFANA_URL', 'http://localhost:3000')}",
  am:       "{os.getenv('ALERTMANAGER_URL', 'http://localhost:9093')}",
  n8n:      "{os.getenv('N8N_URL', 'http://localhost:5678')}",
  mcp:      "{os.getenv('MCP_URL', 'http://localhost:8000')}",
  basePath: "{base_path}",
}};"""
    return Response(content=js, media_type="application/javascript")

@app.get("/dashboard")
async def dashboard_redirect():
    return RedirectResponse(url="/dashboard/")

app.mount("/", StaticFiles(directory="/app/static", html=True), name="static")
