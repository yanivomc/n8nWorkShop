# Agent Prompt — Build Linux MCP Server

> Copy this entire prompt into your AI assistant (Claude, Gemini, ChatGPT, etc.)  
> It will generate all the code you need for the lab.

---

## Prompt

I'm building a Linux Tools MCP (Model Context Protocol) server as a FastAPI application. It will run in a Kubernetes pod and expose Linux diagnostic commands as HTTP endpoints so an AI agent can call them.

Please build the complete implementation with the following spec:

---

### What to build

**1. `server.py`** — FastAPI application

Requirements:
- FastAPI + Uvicorn
- Three endpoints:
  - `GET /health` → returns `{"status": "ok", "service": "linux-mcp-server"}`
  - `GET /tools` → returns a list of available tools with their descriptions
  - `POST /tools/linux-read` → executes a safe Linux command and returns output

The `POST /tools/linux-read` endpoint:
- Accepts JSON body: `{"command": "df -h"}`  
- Runs the command using `subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)`
- Returns JSON: `{"output": "...", "command": "df -h", "error": false, "exit_code": 0}`
- On error returns: `{"output": "error message", "command": "...", "error": true, "exit_code": 1}`
- Has an ALLOWLIST of safe commands — reject anything not in the list with HTTP 403

Allowed commands allowlist:
```python
ALLOWED_PREFIXES = [
    "df", "free", "uptime", "uname",
    "ps", "top -bn1", "netstat", "ss",
    "cat /proc/meminfo", "cat /proc/cpuinfo", "cat /proc/loadavg",
    "hostname", "date", "whoami", "id",
    "ls", "pwd", "env", "printenv", "echo"
]
```

Check: `any(cmd.strip().startswith(prefix) for prefix in ALLOWED_PREFIXES)`

Add logging: `logging.basicConfig(level=logging.INFO)` with format `%(asctime)s | %(levelname)s | linux-mcp | %(message)s`

**2. `requirements.txt`**
```
fastapi
uvicorn
```

**3. `Dockerfile`**
- Base: `python:3.11-slim`
- Working dir: `/app`
- Copy requirements.txt, run pip install
- Copy server.py
- Expose port 8001
- CMD: `uvicorn server:app --host 0.0.0.0 --port 8001`

**4. `deployment.yaml`** — Kubernetes manifest
- Deployment + Service in one file (separated by `---`)
- Namespace: `workshop`
- Deployment name: `linux-mcp-server`
- Label: `app: linux-mcp-server`
- Image: `YOUR_DOCKERHUB_USERNAME/linux-mcp-server:latest` (use placeholder)
- Container port: 8001
- Resources: requests cpu=50m memory=64Mi, limits cpu=200m memory=128Mi
- Service type: ClusterIP, port 8001

**5. Build and deploy instructions** — shell commands to:
- Build the Docker image
- Push to Docker Hub
- Apply the deployment
- Test with curl from inside the cluster

---

### Context

This server will be called by an n8n AI Agent workflow. The agent uses HTTP Request Tool nodes that POST to `/tools/linux-read` with a JSON body. The agent runs inside the same Kubernetes cluster, so it reaches this service via internal DNS: `http://linux-mcp-server.workshop.svc.cluster.local:8001`

The existing K8s MCP server (which this mirrors) is at `http://mcp-server.clawops.svc.cluster.local:8000` and has the same pattern — same FastAPI structure, same response format, same subprocess approach.

---

### Output format

Please produce:
1. Complete `server.py` with all code
2. `requirements.txt`
3. `Dockerfile`
4. `deployment.yaml`  
5. Shell commands to build, push, deploy and test

Make the code production-quality with proper error handling, logging, and comments.
