import os, time, logging, sys
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

logging.basicConfig(stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | dashboard | %(message)s")
logger = logging.getLogger("dashboard")

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

# In-memory instance registry
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
        _instances[inst_id] = {
            "id": inst_id,
            "app": payload.app,
            "version": payload.version,
            "namespace": payload.namespace,
            "pod": payload.pod,
            "url": f"http://{payload.pod}.{payload.namespace}.svc.cluster.local:{payload.port}",
            "registered_at": time.time(),
        }
        logger.info(f"REGISTERED | {inst_id} | {_instances[inst_id]['url']}")
        return {"status": "registered", "id": inst_id}
    except Exception as e:
        logger.error(f"Register error: {e}")
        return JSONResponse({"status": "error", "detail": str(e)}, status_code=500)

@app.get("/api/instances")
async def get_instances():
    logger.info(f"INSTANCES requested | count={len(_instances)}")
    return {"instances": list(_instances.values()), "count": len(_instances)}

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
    """Inject env vars into config.js at runtime."""
    js = f"""window.CLAWOPS_CONFIG = {{
  prom:    "{os.getenv('PROMETHEUS_URL', 'http://localhost:9090')}",
  grafana: "{os.getenv('GRAFANA_URL', 'http://localhost:3000')}",
  am:      "{os.getenv('ALERTMANAGER_URL', 'http://localhost:9093')}",
  n8n:     "{os.getenv('N8N_URL', 'http://localhost:5678')}",
}};"""
    return Response(content=js, media_type="application/javascript")

# Serve static files (index.html) — must be LAST
app.mount("/", StaticFiles(directory="/app/static", html=True), name="static")

from fastapi.responses import Response
