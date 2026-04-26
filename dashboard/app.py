import os, time, logging, sys, asyncio
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel
from contextlib import asynccontextmanager

# ── Chat store (in-memory, ring buffer) ───────────────────────────────────────
import json, time as _time
from collections import deque
from fastapi.responses import StreamingResponse

_chat_messages = deque(maxlen=200)   # persist last 200 messages
_chat_subscribers = []               # active SSE connections

def _chat_event(msg: dict):
    """Store message and fan-out to all SSE subscribers."""
    _chat_messages.append(msg)
    dead = []
    for q in _chat_subscribers:
        try:
            q.put_nowait(msg)
        except Exception:
            dead.append(q)
    for q in dead:
        try: _chat_subscribers.remove(q)
        except: pass

MCP_URL = os.getenv("MCP_INTERNAL_URL", os.getenv("MCP_URL", "http://mcp-server.clawops.svc.cluster.local:8000"))

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

@app.api_route("/api/chaos-loader/{inst_id:path}/{action}", methods=["POST","DELETE","GET"])
async def chaos_loader_proxy(inst_id: str, action: str, request: Request):
    """Proxy to chaos-loader sidecar on port 8003 (same pod as target-app)."""
    inst = _instances.get(inst_id)
    if not inst:
        return JSONResponse({"error": f"instance not found: {inst_id}"}, status_code=404)
    # chaos-loader sidecar shares the pod — same host, port 8003
    internal_url = inst.get("internal_url", "")
    if not internal_url:
        return JSONResponse({"error": "no internal_url for instance"}, status_code=400)
    svc_url = internal_url.replace(":8080", ":8003")
    try:
        body = await request.body()
        params = dict(request.query_params)
        async with httpx.AsyncClient(timeout=10) as c:
            r = await c.request(request.method, f"{svc_url}/{action}", content=body,
                                params=params, headers={"Content-Type": "application/json"})
        return JSONResponse(r.json())
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)

@app.get("/api/pods/{namespace}")
async def get_pods(namespace: str):
    """Proxy: get pods for a namespace via MCP kubectl-read."""
    try:
        r = await _client.post(
            f"{MCP_URL}/tools/kubectl-read",
            json={"command": f"get pods -n {namespace} -o json"},
            timeout=10
        )
        data = r.json()
        raw = data.get("output", "")
        import json as _json
        try:
            return _json.loads(raw)
        except Exception:
            return {"items": [], "error": raw[:200]}
    except Exception as e:
        return {"items": [], "error": str(e)}

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
  n8nInternal: "{os.getenv('N8N_INTERNAL_URL', '')}",
  s4Webhook: "{os.getenv('S4_WEBHOOK_PATH', '/webhook/dashboard-chat')}",
  masterIp: "{os.getenv('MASTER_IP', '')}",
  masterTerminalPort: "{os.getenv('MASTER_TERMINAL_PORT', '5000')}",
  masterVscodePort: "{os.getenv('MASTER_VSCODE_PORT', '5001')}",
}};"""
    return Response(content=js, media_type="application/javascript")

# ── Chat API ──────────────────────────────────────────────────────────────────
class ChatMsg(BaseModel):
    role: str        # "system" | "agent" | "user"
    content: str
    meta: dict = {}  # optional: alertname, key, severity etc

    @classmethod
    def __get_validators__(cls):
        yield cls.validate

    model_config = {"arbitrary_types_allowed": True}

    def __init__(self, **data):
        if isinstance(data.get("meta"), str):
            import json as _json
            try:
                data["meta"] = _json.loads(data["meta"])
            except Exception:
                data["meta"] = {}
        super().__init__(**data)

@app.post("/api/chat/send")
async def chat_send(msg: ChatMsg):
    """n8n → dashboard: post a message (incident alert, execution result)."""
    payload = {
        "id": int(_time.time() * 1000),
        "role": msg.role,
        "content": msg.content,
        "meta": msg.meta,
        "ts": _time.strftime("%H:%M:%S")
    }
    _chat_event(payload)
    return {"ok": True}

@app.post("/api/chat/message")
async def chat_message(request: Request):
    """Browser → n8n: student types a message (e.g. /approve 123456 k42a)."""
    body = await request.json()
    text = body.get("text", "").strip()
    if not text:
        return {"ok": False, "error": "empty message"}

    # Echo to chat as user message
    payload = {
        "id": int(_time.time() * 1000),
        "role": "user",
        "content": text,
        "meta": {},
        "ts": _time.strftime("%H:%M:%S")
    }
    _chat_event(payload)

    # Forward to n8n S4 webhook
    n8n_url = os.getenv("N8N_INTERNAL_URL", "http://n8n.clawops.svc.cluster.local:5678")
    webhook_path = os.getenv("S4_WEBHOOK_PATH", "/webhook/dashboard-chat")
    try:
        r = await _client.post(
            f"{n8n_url}{webhook_path}",
            json={"text": text, "chatId": "dashboard", "from": "student"},
            timeout=5.0
        )
        return {"ok": True, "forwarded": r.status_code}
    except Exception as e:
        logger.warning(f"Could not forward to n8n: {e}")
        return {"ok": True, "forwarded": False}

@app.get("/api/chat/history")
async def chat_history():
    """Return all buffered messages for reconnecting clients."""
    return list(_chat_messages)

@app.get("/api/chat/stream")
async def chat_stream(request: Request):
    """SSE endpoint — browser connects and receives real-time chat messages."""
    import asyncio
    queue = asyncio.Queue()
    _chat_subscribers.append(queue)

    async def event_generator():
        # Send history first
        for msg in list(_chat_messages):
            yield f"data: {json.dumps(msg)}\n\n"
        # Stream new messages
        try:
            while not await request.is_disconnected():
                try:
                    msg = await asyncio.wait_for(queue.get(), timeout=15.0)
                    yield f"data: {json.dumps(msg)}\n\n"
                except asyncio.TimeoutError:
                    yield f": ping\n\n"  # keep-alive
        finally:
            try: _chat_subscribers.remove(queue)
            except: pass

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        }
    )

@app.get("/dashboard")
async def dashboard_redirect():
    return RedirectResponse(url="/dashboard/")

app.mount("/", StaticFiles(directory="/app/static", html=True), name="static")
