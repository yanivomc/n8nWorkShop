# 🧪 Lab — Build a Linux Tools MCP Server

**Session:** S4/S5 Extension  
**Duration:** 45–60 min  
**Difficulty:** Intermediate  

---

## 🎯 Objective

You will build a second MCP server that exposes Linux OS diagnostic tools as HTTP endpoints — following the exact same pattern as the existing K8s MCP server you've been using all day.

Once deployed, you will wire it into the existing n8n AI Agent workflow. The agent will automatically start using it to answer questions like "what's the memory usage?" or "is the process still running?" — without changing the agent logic, just by adding a new tool node.

---

## 📐 Architecture

```
AI Agent (n8n)
  ├── kubectl_read  → K8s MCP Server  (already exists)
  ├── promql        → K8s MCP Server  (already exists)
  └── linux_read    → Linux MCP Server  ← YOU BUILD THIS
```

---

## 📋 What You Need to Build

### 1. `server.py` — FastAPI MCP Server

**Framework:** FastAPI + Uvicorn  
**Base image pattern:** Same as existing `mcp-server/server.py`

**Endpoints required:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Returns `{"status": "ok"}` |
| GET | `/tools` | Lists available tools |
| POST | `/tools/linux-read` | Execute safe read-only Linux commands |

**`POST /tools/linux-read` spec:**

Request body:
```json
{
  "command": "df -h"
}
```

Response:
```json
{
  "output": "Filesystem      Size  Used Avail Use% Mounted on\n...",
  "command": "df -h",
  "error": false,
  "exit_code": 0
}
```

**Allowed commands (allowlist — ONLY these, reject everything else):**
```python
ALLOWED_COMMANDS = [
    "df", "free", "uptime", "uname",
    "ps", "top", "netstat", "ss",
    "cat /proc/meminfo", "cat /proc/cpuinfo", "cat /proc/loadavg",
    "hostname", "date", "whoami", "id",
    "ls", "pwd", "env", "printenv"
]
```

If the command is not in the allowlist → return HTTP 403:
```json
{"detail": "Command not allowed. Use: df, free, uptime, ps, top, netstat..."}
```

Run the command using `subprocess.run` with `shell=True`, capture stdout/stderr, timeout 15s.

**Requirements:**
```
fastapi
uvicorn
```

---

### 2. `Dockerfile`

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY server.py .
EXPOSE 8001
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8001"]
```

Note: Use port **8001** (not 8000 — that's the K8s MCP server).

---

### 3. `deployment.yaml`

Deploy to the `workshop` namespace alongside `target-app`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: linux-mcp-server
  namespace: workshop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: linux-mcp-server
  template:
    metadata:
      labels:
        app: linux-mcp-server
    spec:
      containers:
        - name: linux-mcp-server
          image: <YOUR_DOCKERHUB>/linux-mcp-server:latest
          ports:
            - containerPort: 8001
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: linux-mcp-server
  namespace: workshop
spec:
  selector:
    app: linux-mcp-server
  ports:
    - port: 8001
      targetPort: 8001
  type: ClusterIP
```

Internal DNS: `http://linux-mcp-server.workshop.svc.cluster.local:8001`

---

### 4. n8n Workflow — Add `linux_read` tool

In your **S4 workflow** (K8s Assistant), add a new **HTTP Request Tool** node:

| Setting | Value |
|---------|-------|
| Name | `linux_read` |
| Tool Description | `Run Linux diagnostic commands on the cluster node. Examples: df -h, free -m, uptime, ps aux, netstat -tlnp` |
| Method | POST |
| URL | `http://linux-mcp-server.workshop.svc.cluster.local:8001/tools/linux-read` |
| Body | JSON |
| JSON Body | `={"command": "{command}"}` |

Connect it to the **K8s Assistant** node (same as `kubectl_read` and `promql`).

---

### 5. Update AI System Prompt

In the **K8s Assistant** node, add to the system prompt:

```
5. linux_read — Linux OS diagnostics on the cluster node.
   Parameter: "command"
   Examples: df -h, free -m, uptime, ps aux | grep <name>, netstat -tlnp
   Use this when asked about disk space, memory, processes, or system load.
```

---

## 🚀 Deploy Steps

```bash
# 1. Build and push your image
cd linux-mcp-server/
docker build -t <YOUR_DOCKERHUB>/linux-mcp-server:latest .
docker push <YOUR_DOCKERHUB>/linux-mcp-server:latest

# 2. Deploy to cluster
kubectl apply -f deployment.yaml

# 3. Verify pod is running
kubectl get pods -n workshop -l app=linux-mcp-server

# 4. Test the endpoint
MCP_IP=$(kubectl get svc linux-mcp-server -n workshop -o jsonpath='{.spec.clusterIP}')
curl -s -X POST http://${MCP_IP}:8001/tools/linux-read \
  -H "Content-Type: application/json" \
  -d '{"command": "df -h"}'
```

---

## ✅ Validation

In the dashboard chat, ask:

1. `"how much disk space is available on the node?"`  
   → Agent should call `linux_read` with `df -h`

2. `"what's the memory usage right now?"`  
   → Agent should call `linux_read` with `free -m`

3. `"what processes are running as root?"`  
   → Agent should call `linux_read` with `ps aux`

---

## 🎓 Bonus Challenge

Add a second endpoint `/tools/linux-write` that allows **only** `kill <pid>` with TOTP approval — following the exact same pattern as `kubectl-write` in the K8s MCP server.

---

## 💡 Hints

- Look at `mcp-server/server.py` in the repo — your server follows the exact same structure
- The `subprocess.run` pattern is already used in the K8s MCP server
- The n8n tool node wiring is identical to `kubectl_read` — just change the URL and description
- If the agent doesn't use your tool automatically, check the tool description — it needs to clearly explain when to use it
