from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess
import requests
import os
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="n8n Workshop MCP Server",
    description="Three tools: run_kubectl_read, run_promql, run_kubectl_write (gated)",
    version="1.0.0"
)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus-server:9090")
KUBECONFIG = os.getenv("KUBECONFIG", "/root/.kube/config")

# ── Request models ────────────────────────────────────────────────────────────

class KubectlRequest(BaseModel):
    command: str  # e.g. "get pods -n prod -l app=payments"

class PromQLRequest(BaseModel):
    query: str    # e.g. "rate(http_requests_total[5m])"
    duration: str = "5m"  # for range queries

class WriteRequest(BaseModel):
    command: str         # e.g. "rollout restart deployment/payments -n prod"
    approved_by: str     # must be set by n8n after human approves
    approval_token: str  # token from n8n approval workflow

# ── Helpers ───────────────────────────────────────────────────────────────────

WRITE_VERBS = {"delete", "apply", "create", "replace", "patch",
               "rollout", "scale", "cordon", "drain", "taint", "label", "annotate"}

def is_write_command(command: str) -> bool:
    first_word = command.strip().split()[0].lower()
    return first_word in WRITE_VERBS

def run_kubectl(command: str, timeout: int = 30) -> str:
    full_cmd = f"kubectl {command} --kubeconfig={KUBECONFIG}"
    logger.info(f"Running: {full_cmd}")
    result = subprocess.run(
        full_cmd, shell=True, capture_output=True, text=True, timeout=timeout
    )
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=f"kubectl error: {result.stderr.strip()}")
    return result.stdout.strip()

# ── Tool 1: READ ──────────────────────────────────────────────────────────────

@app.post("/tools/kubectl-read")
async def run_kubectl_read(req: KubectlRequest):
    """
    Run any read-only kubectl command.
    Agent calls this freely. No approval needed.
    Examples: get pods -n prod, describe pod payments-xxx -n prod, logs payments-xxx -n prod --tail=50
    """
    if is_write_command(req.command):
        raise HTTPException(
            status_code=403,
            detail=f"Write command detected. Use /tools/kubectl-write with human approval. Command: {req.command}"
        )
    output = run_kubectl(req.command)
    return {"output": output, "command": f"kubectl {req.command}"}

# ── Tool 2: PROMQL ────────────────────────────────────────────────────────────

@app.post("/tools/promql")
async def run_promql(req: PromQLRequest):
    """
    Run any PromQL query against Prometheus.
    Agent calls this freely. No approval needed.
    Examples: rate(container_cpu_usage_seconds_total{pod=~'payments.*'}[5m])
    """
    try:
        resp = requests.get(
            f"{PROMETHEUS_URL}/api/v1/query",
            params={"query": req.query},
            timeout=10
        )
        resp.raise_for_status()
        data = resp.json()
        if data["status"] != "success":
            raise HTTPException(status_code=500, detail=f"Prometheus error: {data}")
        return {"result": data["data"]["result"], "query": req.query}
    except requests.RequestException as e:
        raise HTTPException(status_code=503, detail=f"Prometheus unreachable: {str(e)}")

# ── Tool 3: WRITE (GATED) ─────────────────────────────────────────────────────

@app.post("/tools/kubectl-write")
async def run_kubectl_write(req: WriteRequest):
    """
    Run a write kubectl command. GATED.
    This endpoint is called by n8n ONLY after human approval via Telegram.
    The agent never calls this directly — n8n enforces the human loop.
    Requires: approved_by (engineer name) and approval_token (from n8n workflow).
    """
    # Validate approval token (n8n generates this, passes it after Telegram YES)
    expected_token = os.getenv("WRITE_APPROVAL_TOKEN", "")
    if not expected_token or req.approval_token != expected_token:
        logger.warning(f"Write attempt with invalid token by {req.approved_by}: {req.command}")
        raise HTTPException(status_code=403, detail="Invalid approval token. Human approval required.")

    if not is_write_command(req.command):
        raise HTTPException(status_code=400, detail="Not a write command. Use /tools/kubectl-read instead.")

    logger.info(f"WRITE approved by {req.approved_by}: kubectl {req.command}")
    output = run_kubectl(req.command, timeout=60)

    return {
        "output": output,
        "command": f"kubectl {req.command}",
        "approved_by": req.approved_by,
        "status": "executed"
    }

# ── Health + docs ─────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "tools": ["kubectl-read", "promql", "kubectl-write"]}

@app.get("/tools")
async def list_tools():
    """Returns tool descriptions for the n8n AI Agent node to understand available capabilities."""
    return {
        "tools": [
            {
                "name": "kubectl-read",
                "endpoint": "/tools/kubectl-read",
                "description": "Run any read-only kubectl command. Use for: get pods, describe, logs, events, top.",
                "example": "get pods -n prod -l app=payments --sort-by=.status.startTime"
            },
            {
                "name": "promql",
                "endpoint": "/tools/promql",
                "description": "Run any PromQL query against Prometheus for live metrics.",
                "example": "rate(container_memory_usage_bytes{pod=~'payments.*'}[5m])"
            },
            {
                "name": "kubectl-write",
                "endpoint": "/tools/kubectl-write",
                "description": "GATED. Run write kubectl commands. Called by n8n ONLY after Telegram human approval.",
                "example": "rollout restart deployment/payments -n prod"
            }
        ]
    }

