from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import subprocess, requests, os, logging, pyotp

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="n8n Workshop MCP Server",
    description="3 tools: kubectl-read (free), promql (free), kubectl-write (gated)",
    version="1.0.0"
)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus-server:9090")
KUBECONFIG     = os.getenv("KUBECONFIG", "/root/.kube/config")
TOTP_SECRET    = os.getenv("TOTP_SECRET", "")          # base32 secret for Authy/Google Auth
WRITE_TOKEN    = os.getenv("WRITE_APPROVAL_TOKEN", "")  # fallback static token

WRITE_VERBS = {
    "delete","apply","create","replace","patch",
    "rollout","scale","cordon","drain","taint","label","annotate"
}

class KubectlRequest(BaseModel):
    command: str

class PromQLRequest(BaseModel):
    query: str

class WriteRequest(BaseModel):
    command:        str
    approved_by:    str
    approval_token: str  # TOTP code (6 digits) or static token


def validate_token(supplied: str) -> bool:
    """Validate TOTP code first, fallback to static token."""
    # Try TOTP if secret is configured
    if TOTP_SECRET:
        try:
            totp = pyotp.TOTP(TOTP_SECRET)
            if totp.verify(supplied, valid_window=1):  # ±30s window
                return True
        except Exception as e:
            logger.warning(f"TOTP validation error: {e}")
    # Fallback: static token
    if WRITE_TOKEN and supplied == WRITE_TOKEN:
        return True
    return False


def is_write_command(cmd: str) -> bool:
    return cmd.strip().split()[0].lower() in WRITE_VERBS

def run_kubectl(cmd: str, timeout: int = 30) -> dict:
    full = f"kubectl {cmd} --kubeconfig={KUBECONFIG}"
    logger.info(f"kubectl: {full}")
    r = subprocess.run(full, shell=True, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        # Return the actual kubectl error message — not a 500.
        # "pod not found", "namespace not found" etc. are valid K8s responses
        # the AI Agent can read and reason about.
        error_msg = r.stderr.strip() or r.stdout.strip() or "kubectl returned no output"
        logger.warning(f"kubectl non-zero exit ({r.returncode}): {error_msg}")
        return {"output": error_msg, "exit_code": r.returncode, "error": True}
    return {"output": r.stdout.strip(), "exit_code": 0, "error": False}


# ── Tool 1: READ (agent calls freely) ───────────────────────────────
@app.post("/tools/kubectl-read")
async def kubectl_read(req: KubectlRequest):
    """Any read-only kubectl command. get, describe, logs, events, top."""
    if is_write_command(req.command):
        raise HTTPException(
            status_code=403,
            detail=f"Write command blocked. Use /tools/kubectl-write with approval. cmd={req.command}"
        )
    result = run_kubectl(req.command)
    return {"output": result["output"], "command": f"kubectl {req.command}", "error": result["error"], "exit_code": result["exit_code"]}


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
    if not validate_token(req.approval_token):
        logger.warning(f"Blocked write by {req.approved_by}: {req.command}")
        raise HTTPException(status_code=403, detail="Invalid token. Use TOTP code from Authy/Google Authenticator.")
    if not is_write_command(req.command):
        raise HTTPException(status_code=400, detail="Not a write command.")

    logger.info(f"WRITE approved by {req.approved_by}: kubectl {req.command}")
    result = run_kubectl(req.command, timeout=60)
    return {
        "output":      result["output"],
        "command":     f"kubectl {req.command}",
        "approved_by": req.approved_by,
        "status":      "executed" if not result["error"] else "failed",
        "error":       result["error"]
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
