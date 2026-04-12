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
    "delete","apply","create","replace","patch","run",
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

    logger.info(f"AUDIT | WRITE_EXECUTED | approved_by={req.approved_by} | command=kubectl {req.command} | timestamp=" + __import__("datetime").datetime.utcnow().isoformat())
    result = run_kubectl(req.command, timeout=60)
    return {
        "output":      result["output"],
        "command":     f"kubectl {req.command}",
        "approved_by": req.approved_by,
        "status":      "executed" if not result["error"] else "failed",
        "error":       result["error"]
    }


# ── Health + tool listing ────────────────────────────────────────────
@app.get("/discovery")
async def discover_pods():
    """
    Auto-discover target-app pods in K8s.
    Returns list of pods with app=target-app label across all namespaces.
    Dashboard polls this to auto-register instances.
    """
    try:
        result = run_kubectl(
            "get pods -A -l app=target-app -o jsonpath='{range .items[*]}{.metadata.name},{.metadata.namespace},{.status.podIP},{.status.phase}{\"\\n\"}{end}'",
            timeout=10
        )
        pods = []
        if not result.get("error") and result.get("output"):
            for line in result["output"].strip().split("\n"):
                if not line.strip():
                    continue
                try:
                    name, namespace, ip, phase = line.split(",")
                    if phase == "Running" and ip:
                        pods.append({
                            "pod": name,
                            "namespace": namespace,
                            "ip": ip,
                            "url": f"http://{ip}:8080",
                            "phase": phase
                        })
                except Exception:
                    continue
        logger.info(f"Discovery: found {len(pods)} target-app pods")
        return {"pods": pods, "count": len(pods)}
    except Exception as e:
        logger.error(f"Discovery error: {e}")
        return {"pods": [], "count": 0, "error": str(e)}


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


# ── Incident Store (SQLite) ───────────────────────────────────────────────────
import sqlite3, random, string, time
from datetime import datetime

DB_PATH = os.getenv("INCIDENTS_DB", "/data/incidents.db")

def get_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("""CREATE TABLE IF NOT EXISTS incidents (
        key         TEXT PRIMARY KEY,
        alertname   TEXT,
        namespace   TEXT,
        pod         TEXT,
        command     TEXT,
        status      TEXT DEFAULT 'pending',
        created_at  TEXT,
        resolved_at TEXT
    )""")
    conn.commit()
    return conn

def gen_key():
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=4))

class IncidentCreate(BaseModel):
    alertname: str
    namespace: str = "workshop"
    pod: str = ""
    command: str

class IncidentUpdate(BaseModel):
    status: str  # approved / resolved / dismissed

@app.post("/incidents")
def create_incident(req: IncidentCreate):
    key = gen_key()
    now = datetime.utcnow().isoformat()
    with get_db() as conn:
        conn.execute(
            "INSERT INTO incidents (key,alertname,namespace,pod,command,status,created_at) VALUES (?,?,?,?,?,?,?)",
            (key, req.alertname, req.namespace, req.pod, req.command, 'pending', now)
        )
    logger.info(f"INCIDENT CREATED | key={key} | {req.alertname} | {req.command}")
    return {"key": key, "status": "pending", "created_at": now}

@app.get("/incidents/{key}")
def get_incident(key: str):
    with get_db() as conn:
        row = conn.execute("SELECT * FROM incidents WHERE key=?", (key,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Incident not found")
    return dict(row)

@app.patch("/incidents/{key}")
def update_incident(key: str, req: IncidentUpdate):
    now = datetime.utcnow().isoformat()
    with get_db() as conn:
        conn.execute(
            "UPDATE incidents SET status=?, resolved_at=? WHERE key=?",
            (req.status, now, key)
        )
    logger.info(f"INCIDENT UPDATED | key={key} | status={req.status}")
    return {"key": key, "status": req.status}

@app.get("/incidents")
def list_incidents(limit: int = 50):
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM incidents ORDER BY created_at DESC LIMIT ?", (limit,)
        ).fetchall()
    return {"incidents": [dict(r) for r in rows], "count": len(rows)}
