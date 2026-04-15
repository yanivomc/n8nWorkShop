import os, subprocess, logging, sys
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

logging.basicConfig(
    stream=sys.stdout, level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | linux-mcp | %(message)s"
)
logger = logging.getLogger("linux-mcp")

app = FastAPI(
    title="Linux Tools MCP Server",
    description="Safe Linux diagnostic commands for AI agents",
    version="1.0.0"
)

# ── Allowlist ────────────────────────────────────────────────────────────────
ALLOWED_PREFIXES = [
    "df", "free", "uptime", "uname",
    "ps", "top -bn1", "netstat", "ss",
    "cat /proc/meminfo", "cat /proc/cpuinfo", "cat /proc/loadavg",
    "hostname", "date", "whoami", "id",
    "ls", "pwd", "env", "printenv", "echo",
    "lscpu", "lsmem", "nproc",
]

def is_allowed(cmd: str) -> bool:
    cmd = cmd.strip()
    return any(cmd.startswith(prefix) for prefix in ALLOWED_PREFIXES)

def run_command(cmd: str, timeout: int = 15) -> dict:
    logger.info(f"RUN: {cmd}")
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True,
            text=True, timeout=timeout
        )
        if r.returncode != 0:
            error_msg = r.stderr.strip() or r.stdout.strip() or "command returned non-zero exit"
            logger.warning(f"EXIT {r.returncode}: {error_msg}")
            return {"output": error_msg, "command": cmd, "error": True, "exit_code": r.returncode}
        return {"output": r.stdout.strip(), "command": cmd, "error": False, "exit_code": 0}
    except subprocess.TimeoutExpired:
        return {"output": f"Command timed out after {timeout}s", "command": cmd, "error": True, "exit_code": -1}
    except Exception as e:
        return {"output": str(e), "command": cmd, "error": True, "exit_code": -1}


# ── Models ────────────────────────────────────────────────────────────────────
class LinuxRequest(BaseModel):
    command: str


# ── Endpoints ─────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {"status": "ok", "service": "linux-mcp-server", "version": "1.0.0"}


@app.get("/tools")
def list_tools():
    return {
        "tools": [
            {
                "name": "linux-read",
                "endpoint": "/tools/linux-read",
                "method": "POST",
                "description": "Run safe read-only Linux diagnostic commands",
                "allowed_commands": ALLOWED_PREFIXES,
                "example": "df -h"
            }
        ]
    }


@app.post("/tools/linux-read")
def linux_read(req: LinuxRequest):
    """Safe read-only Linux diagnostics — free, df, ps, netstat, etc."""
    cmd = req.command.strip()
    if not cmd:
        raise HTTPException(status_code=400, detail="Empty command")
    if not is_allowed(cmd):
        allowed = ", ".join(ALLOWED_PREFIXES)
        logger.warning(f"BLOCKED: {cmd}")
        raise HTTPException(
            status_code=403,
            detail=f"Command not allowed. Permitted prefixes: {allowed}"
        )
    return run_command(cmd)
