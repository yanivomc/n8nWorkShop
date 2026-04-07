from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess, requests, os, logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="n8n Workshop MCP Server",
    description="3 tools: kubectl-read (free), promql (free), kubectl-write (gated)",
    version="1.0.0"
)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus-server:9090")
KUBECONFIG     = os.getenv("KUBECONFIG", "/root/.kube/config")

WRITE_VERBS = {
    "delete","apply","create","replace","patch",
    "rollout","scale","cordon","drain","taint","label","annotate"
}

class KubectlRequest(BaseModel):
    command: str   # e.g. "get pods -n prod -l app=payments"

class PromQLRequest(BaseModel):
    query: str     # e.g. "rate(container_cpu_usage_seconds_total[5m])"

class WriteRequest(BaseModel):
    command:        str   # e.g. "rollout restart deployment/payments -n prod"
    approved_by:    str   # engineer name from Telegram approval
    approval_token: str   # token set in .env, passed by n8n after human YES


def is_write_command(cmd: str) -> bool:
    return cmd.strip().split()[0].lower() in WRITE_VERBS

def run_kubectl(cmd: str, timeout: int = 30) -> str:
    full = f"kubectl {cmd} --kubeconfig={KUBECONFIG}"
    logger.info(f"kubectl: {full}")
    r = subprocess.run(full, shell=True, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise HTTPException(status_code=500, detail=f"kubectl error: {r.stderr.strip()}")
    return r.stdout.strip()


# ── Tool 1: READ (agent calls freely) ───────────────────────────────
@app.post("/tools/kubectl-read")
async def kubectl_read(req: KubectlRequest):
    """Any read-only kubectl command. get, describe, logs, events, top."""
    if is_write_command(req.command):
        raise HTTPException(
            status_code=403,
            detail=f"Write command blocked. Use /tools/kubectl-write with approval. cmd={req.command}"
        )
    return {"output": run_kubectl(req.command), "command": f"kubectl {req.command}"}


# ── Tool 2: PROMQL (agent calls freely) ─────────────────────────────
@app.post("/tools/promql")
async def run_promql(req: PromQLRequest):
    """Any PromQL query against Prometheus."""
    try:
        r = requests.get(f"{PROMETHEUS_URL}/api/v1/query",
                         params={"query": req.query}, timeout=10)
        r.raise_for_status()
        data = r.json()
        if data["status"] != "success":
            raise HTTPException(status_code=500, detail=str(data))
        return {"result": data["data"]["result"], "query": req.query}
    except requests.RequestException as e:
        raise HTTPException(status_code=503, detail=f"Prometheus unreachable: {e}")


# ── Tool 3: WRITE (GATED — n8n calls only after Telegram YES) ───────
@app.post("/tools/kubectl-write")
async def kubectl_write(req: WriteRequest):
    """
    Write kubectl command. GATED.
    n8n calls this ONLY after human approved via Telegram.
    Agent never calls this directly.
    """
    expected = os.getenv("WRITE_APPROVAL_TOKEN", "")
    if not expected or req.approval_token != expected:
        logger.warning(f"Blocked write by {req.approved_by}: {req.command}")
        raise HTTPException(status_code=403, detail="Invalid approval token.")
    if not is_write_command(req.command):
        raise HTTPException(status_code=400, detail="Not a write command.")

    logger.info(f"WRITE approved by {req.approved_by}: kubectl {req.command}")
    output = run_kubectl(req.command, timeout=60)
    return {
        "output":      output,
        "command":     f"kubectl {req.command}",
        "approved_by": req.approved_by,
        "status":      "executed"
    }


# ── Health + tool listing ────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "tools": ["kubectl-read", "promql", "kubectl-write"]}

@app.get("/tools")
async def list_tools():
    """Tool descriptions for the n8n AI Agent node."""
    return {"tools": [
        {
            "name":        "kubectl-read",
            "endpoint":    "/tools/kubectl-read",
            "description": "Run any read-only kubectl command: get, describe, logs, events, top.",
            "example":     "get pods -n prod -l app=payments --sort-by=.status.startTime"
        },
        {
            "name":        "promql",
            "endpoint":    "/tools/promql",
            "description": "Run any PromQL query against Prometheus for live metrics.",
            "example":     "rate(container_memory_usage_bytes{pod=~'payments.*'}[5m])"
        },
        {
            "name":        "kubectl-write",
            "endpoint":    "/tools/kubectl-write",
            "description": "GATED. Write kubectl commands. Called by n8n ONLY after Telegram approval.",
            "example":     "rollout restart deployment/payments -n prod"
        }
    ]}
