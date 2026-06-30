# CLAUDE.md — ClawOps Workshop AI Context

This file gives AI assistants full context about this project so you can help without lengthy explanations.

---

## What This Project Is

**ClawOps** is an 8-hour hands-on DevOps workshop teaching AI-assisted incident command. Students operate a real Kubernetes cluster, trigger chaos scenarios, watch AI agents investigate them, and approve fixes via a TOTP-gated approval gate — all through a custom dashboard chat interface.

**Core thesis:** "You don't build incident response workflows manually anymore — AI helps you build and operate them. But you still own the architecture and the approval gate."

---

## Architecture

```
K8s Cluster (kops, AWS, 2 nodes)
  clawops namespace:
    n8n (port 5678) — workflow automation, AI agent, S4+S5 workflows
    mcp-server (port 8000) — kubectl + promql tools + SQLite incident store
    clawops-dashboard (port 80) — incident command UI + SSE real-time chat

  workshop namespace:
    target-app (port 8080) — chaos scenarios + Prometheus metrics
    linux-mcp-server (port 8001) — safe Linux diagnostic commands

  monitoring namespace:
    Prometheus, Grafana, Alertmanager — all ClusterIP
    Accessed via ingress: /prometheus, /grafana, /alertmanager/

  ingress-nginx:
    ONE nginx LB for everything
    / → n8n
    /dashboard/ → clawops-dashboard
    /mcp/ → mcp-server
    /prometheus → prometheus (no rewrite)
    /grafana → grafana (no rewrite)
    /alertmanager/ → alertmanager
```

---

## Bootstrap

```bash
./bootstrap-k8s.sh run     # non-interactive full bootstrap
./bootstrap-k8s.sh         # interactive menu (8 options)
```

Menu options:
- 1 = full bootstrap (install/upgrade everything)
- 2 = update configs (refresh configmaps + restart pods)
- 3 = update ingress
- 4 = import workflows (S2/S4/S5/S6/S8)
- 5 = show TOTP + QR code (instructor — scan with Authy)
- 6 = reset incidents (clear all MCP incidents)
- 7 = validate health checks
- 8 = delete ALL resources

A fresh `run` deploys **everything** (ingress-nginx, monitoring, n8n, mcp-server,
dashboard, event-watcher, linux-mcp-server, target-app, ingress, + auto-imports
workflows). Students still attach the **Gemini credential** + **activate** the
imported workflows by hand (by design).

---

## Repository Structure

```
bootstrap-k8s.sh              # The one script to rule them all
k8s/
  clawops/                    # n8n, mcp-server, dashboard, event-watcher, linux-mcp
    mcp-server/rbac.yaml      # ServiceAccount for in-cluster K8s auth
    n8n/deployment.yaml       # pinned 1.123.62; .cache on emptyDir (not the PVC)
    event-watcher/            # K8s event watcher → dashboard SSE + S6/S8 webhooks
    linux-mcp-server/         # Linux tools MCP (runs in clawops ns)
  workshop/
    target-app/               # Chaos app + chaos-loader sidecar (768Mi limit)
  ingress/
    ingress.yaml              # All named ingress resources (incl. /events-admin/)
  monitoring/
    prometheus-values.yaml    # Helm values — ClusterIP, alert rules, subpaths,
                              # defaultRules noise-suppression, INJECT_INGRESS_LB
mcp-server/server.py          # FastAPI: kubectl-read, promql, kubectl-write, /incidents
linux-mcp-server/server.py    # FastAPI: linux-read (df, free, ps, etc.)
target-app/                   # Chaos engineering app
dashboard/
  app.py                      # FastAPI: SSE chat, chaos proxy, incidents proxy
  index.html                  # Dashboard UI (vanilla JS)
n8n-workflows/
  s2-ai-agent-mcp.json            # Chat trigger → K8s + PromQL agent
  s2.5-linux-agent.json           # Chat trigger → K8s + Linux + PromQL agent
  s4-dashboard-human-loop.json    # Dashboard chat → AI → TOTP → kubectl-write
  s5-alert-intelligence.json      # Alert webhook → AI enrich → dashboard chat
  s6-k8s-event-intelligence.json  # K8s-event webhook → AI investigate → chat
  s8-k8s-event-jwt.json           # S6 + JWT-secured event webhook
labs/
  lab-linux-mcp-server.md     # Student lab: build Linux MCP server
  linux-mcp-agent-prompt.md   # AI prompt students give to their AI
```

---

## Sessions

| # | Session | Trigger | Output |
|---|---------|---------|--------|
| S2 | AI Agent + MCP | n8n Chat UI | n8n chat sidebar |
| S2.5 | Linux + K8s Agent | n8n Chat UI | n8n chat sidebar |
| S4 | Human Loop | Webhook `/dashboard-chat` | Dashboard chat |
| S5 | Alert Intelligence | Alertmanager webhook `/prometheus-alert-s5` | Dashboard chat |
| S6 | K8s Event Intelligence | event-watcher webhook `/k8s-event-s6` | Dashboard chat |
| S8 | JWT-Secured Events | event-watcher webhook `/k8s-event-s8` (Bearer JWT) | Dashboard chat |

**S2/S2.5 use n8n's built-in Chat Trigger** — students interact via n8n UI at `http://<LB>/`

**S4/S5/S6/S8 use dashboard chat** — students interact via `http://<LB>/dashboard/` → CHAT tab

> **Numbering note:** `Sx` are historical *build-order* file IDs, NOT teaching
> order. Slides teach detect → approve: **Section 3 = Alert Intelligence (s5)**
> before **Section 4 = Human Approval (s4)**. Don't renumber — the IDs are in
> ~14 files incl. the live Alertmanager webhook path. (S5 hands off to S4 via the
> incident key; S6/S8 detect K8s events instead of metric alerts.)

---

## Critical Implementation Details

### n8n Code Node Restrictions
```
❌ fetch(), $httpRequest(), require('http') — BLOCKED in Code nodes
✅ Use HTTP Request nodes for all external calls
✅ Expressions in HTTP Request nodes CAN reference other nodes
```

### Workflow Import
Always strip `id` and `versionId` before importing — n8n rejects duplicates:
```python
d.pop('id', None); d.pop('versionId', None)
```

### n8n HTTP Body Format
For HTTP Request nodes sending to dashboard `/api/chat/send`:
```json
bodyParameters: {
  parameters: [
    { name: "role", value: "agent" },
    { name: "content", value: "={{ $json.message }}" }
  ]
}
```
NOT `jsonBody` with inline expressions — those produce invalid JSON.

### Dashboard Subpath
- All JS API calls use `API_BASE` computed from `window.CLAWOPS_CONFIG.basePath`
- `config.js` served at `/dashboard/config.js` (relative, not absolute path)
- `MCP_URL` in app.py is for browser nav links; `MCP_INTERNAL_URL` is for server-side proxy calls

### Monitoring Subpaths
- Prometheus: `routePrefix: /prometheus` in helm values + Prefix ingress (NO rewrite)
- Grafana: `GF_SERVER_ROOT_URL` + `GF_SERVER_SERVE_FROM_SUB_PATH` env vars + Prefix ingress (NO rewrite)
- Alertmanager: `routePrefix: /` + regex ingress with rewrite

### TOTP Generation
**Must use pyotp inside MCP pod** — EC2 K8s master has no pip3:
```bash
kubectl exec -n clawops deployment/mcp-server -- python3 -c "import pyotp; print(pyotp.random_base32())"
```
After changing secret: `kubectl rollout restart deployment/mcp-server -n clawops`

### MCP In-Cluster Auth
MCP server uses K8s ServiceAccount (no kubeconfig):
- ServiceAccount: `mcp-server` in `clawops` namespace
- ClusterRole: read-all + write to workshop namespace
- Applied by bootstrap: `kubectl apply -f k8s/clawops/mcp-server/rbac.yaml`

### Execute Write — kubectl prefix
MCP `/tools/kubectl-write` validates commands against `WRITE_VERBS` list.
The `command` field must NOT include "kubectl" prefix:
```
✅ "rollout restart deployment/target-app -n workshop"
❌ "kubectl rollout restart deployment/target-app -n workshop"
```
Strip it in n8n: `command.replace(/^kubectl\s+/i, '')`

### Incident Key Flow
1. S5 fires → S4 chat → `POST /incidents` on MCP → MCP auto-generates key
2. Key shown in chat: `/approve <totp> k42a`
3. Student approves → `GET /incidents/k42a` → executes → `PATCH /incidents/k42a {status: resolved}`

---

## MCP API Reference

**K8s MCP** `http://mcp-server.clawops.svc.cluster.local:8000`

```
POST /tools/kubectl-read    { command: "get pods -n workshop" }
POST /tools/promql          { query: "up" }
POST /tools/kubectl-write   { command: "rollout restart...", approval_token: "123456", approved_by: "student" }
POST /incidents             { alertname, namespace, pod, command } → { key, status, created_at }
GET  /incidents/{key}       → { key, alertname, namespace, pod, command, status, created_at, resolved_at }
PATCH /incidents/{key}      { status: "resolved" }
GET  /incidents?limit=20    → [ ...incidents ]
GET  /health                → { status: "ok" }
```

**Linux MCP** `http://linux-mcp-server.workshop.svc.cluster.local:8001`

```
POST /tools/linux-read      { command: "df -h" }
GET  /health                → { status: "ok" }
```

---

## Dashboard API Reference

Base: `http://clawops-dashboard.clawops.svc.cluster.local:80`

```
POST /api/register                     { pod, namespace, url, ... } → registers target-app
GET  /api/instances                    → { id: { pod, namespace, url, status, ... } }
POST /api/chaos/{inst_id}/action       { type: "cpu" } → proxied to target-app
POST /api/chat/send                    { role, content, meta? } → stores + SSE broadcast
POST /api/chat/message                 { text } → echo to chat + forward to n8n S4
GET  /api/chat/stream                  SSE endpoint → streams { id, role, content, ts, meta }
GET  /api/chat/history                 → last 200 messages
GET  /api/incidents                    → proxied from MCP
DELETE /api/incidents                  → proxied to MCP
GET  /config.js                        → window.CLAWOPS_CONFIG = { prom, grafana, am, n8n, mcp, basePath, masterIp, ... }
GET  /dashboard                        → 301 redirect to /dashboard/
```

---

## Alert Rules (Prometheus)

All in `k8s/monitoring/prometheus-values.yaml` under `additionalPrometheusRulesMap`.
**Must include `workshop: "true"` label** — Alertmanager routes only `workshop=true` to n8n.

Key alerts:
- `TargetAppCPUStress` — `target_chaos_cpu_active == 1`
- `TargetAppMemoryLeak` — `target_chaos_memory_active == 1`
- `TargetAppHighErrorRate` — `target_chaos_error_active == 1`
- `TargetAppHighLatency` — `target_chaos_latency_active == 1`
- `TargetAppCrashLooping` — restarts > 1 in 5min
- `PodCrashLooping`, `PodOOMKilled`, `PodNotReady`, `DeploymentReplicasMismatch`

---

## Common Tasks

### Rebuild and redeploy a service
The cluster nodes are **x86_64 (amd64)**. Building on an Apple-Silicon Mac
defaults to arm64 and the pod CrashLoops with `exec format error` —
**always build for `linux/amd64`** (works with `docker buildx` or `podman`):
```bash
# docker
docker buildx build --platform linux/amd64 -t yanivomc/clawops-dashboard:latest --push ./dashboard
# podman (build then push)
podman build --platform linux/amd64 -t yanivomc/clawops-dashboard:latest ./dashboard && \
  podman push localhost/yanivomc/clawops-dashboard:latest docker.io/yanivomc/clawops-dashboard:latest
# then
kubectl rollout restart deployment/clawops-dashboard -n clawops
```
Verify arch before pushing: `podman inspect --format '{{.Architecture}}' <image>` → `amd64`.

### Re-apply configmaps with fresh values
```bash
./bootstrap-k8s.sh  # option 2
```

### Check what Alertmanager is sending to
```bash
kubectl get secret alertmanager-monitoring-kube-prometheus-alertmanager \
  -n monitoring -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep url
# Should show: http://n8n.clawops.svc.cluster.local:5678/webhook/prometheus-alert-s5
```

### Test MCP from EC2
```bash
MCP_IP=$(kubectl get svc mcp-server -n clawops -o jsonpath='{.spec.clusterIP}')
curl -s -X POST http://${MCP_IP}:8000/tools/kubectl-read \
  -H 'Content-Type: application/json' -d '{"command":"get pods -n workshop"}'
```

### Test dashboard incidents
```bash
DASH_IP=$(kubectl get svc clawops-dashboard -n clawops -o jsonpath='{.spec.clusterIP}')
curl -s http://${DASH_IP}:80/api/incidents | python3 -m json.tool
```

### Force S5 test (trigger fake alert)
```bash
N8N_IP=$(kubectl get svc n8n -n clawops -o jsonpath='{.spec.clusterIP}')
curl -s -X POST http://${N8N_IP}:5678/webhook/prometheus-alert-s5 \
  -H "Content-Type: application/json" \
  -d '{"alerts":[{"labels":{"alertname":"TargetAppCPUStress","severity":"warning","workshop":"true","namespace":"workshop","pod":"target-app-xxx"},"status":"firing","generatorURL":"http://prometheus/graph"}]}'
```

---

## Known Issues / Gotchas

- **Dead pods in dashboard** — cleanup after 3 poll failures × 5s = 15s. Wait or restart.
- **TOTP invalid** — regenerate using MCP pod (has pyotp). Then restart mcp-server.
- **Config.js showing INJECT_*** — run bootstrap option 2 to re-apply configmaps.
- **Prometheus redirect loop** — do NOT use nginx rewrite with Prometheus. Use Prefix path only.
- **Grafana redirect to localhost** — must use `GF_SERVER_ROOT_URL` env var, not `grafana.ini`.
- **n8n workflow import fails** — strip `id` and `versionId` from JSON.
- **kubectl-write "Not a write command"** — strip "kubectl" prefix before sending to MCP.
- **Alertmanager not sending** — check it's pointing to `n8n.clawops.svc.cluster.local` (not old EC2 IP).

### Fixed in 2026-06 (validated on a fresh cluster — keep these in mind)

- **n8n blank UI / truncated editor JS** — the EBS CSI PVC can truncate a large
  single-file write at a 64KB boundary. n8n templates its ~1MB frontend into
  `~/.n8n/.cache` on startup → truncated → "Unexpected end of input" → blank page.
  Fix: `.cache` is mounted on a node-local **emptyDir** (regenerable, off the PVC)
  in `k8s/clawops/n8n/deployment.yaml`. The SQLite DB stays on the PVC. (Separate
  from the older `:latest`→2.x 0-byte bug, which the `1.123.62` pin fixed.)
- **event-watcher / linux-mcp-server not deployed on fresh clusters** — bootstrap
  referenced an **undefined `$K8S_DIR`** for those two applies, so they failed
  silently. Fixed: all paths use `$CLAWOPS_DIR`. If they're ever missing again,
  check the dir variables in `bootstrap-k8s.sh` resolve.
- **Grafana subpath/scrape broken (TargetDown)** — `GF_SERVER_ROOT_URL` shipped a
  literal `INJECT_INGRESS_LB`. Fixed: bootstrap's prometheus-values render now
  substitutes `INJECT_INGRESS_LB → $INGRESS_LB`. Fixing root_url also recovered
  the /metrics scrape.
- **Memory-leak chaos OOMKilled instead of firing TargetAppMemoryLeak** —
  target-app limit was 512Mi but the leak goes to 500MB. Raised to **768Mi**.
- **Noisy `/prometheus/alerts` on kops** — control-plane + coredns + Watchdog +
  grafana TargetDown alerts are expected kops noise (Alertmanager drops them via
  `null-receiver`). `prometheus-values.yaml` now disables those `defaultRules`
  groups; the `workshop.pods` rules are scoped to `namespace="workshop"` so they
  never fire on system pods (they carry `workshop="true"` and route to n8n).
- **S5 fed the AI fake `CPU Stress=0`** — the old `PromQL Enrichment` Code node
  hardcoded signals to 0 (Code nodes can't do HTTP). Merged into `Extract Brief +
  Signal Plan`: it hands the AI a query PLAN; the AI runs it live via its promql
  tool. The `Worth Escalating?` gate is now real (firing → AI, resolved → log).

---

## Docker Images

| Image | Built from |
|-------|-----------|
| `yanivomc/target-app:latest` | `target-app/` |
| `yanivomc/chaos-loader:latest` | `chaos-loader/` |
| `yanivomc/clawops-dashboard:latest` | `dashboard/` |
| `yanivomc/mcp-server:latest` | `mcp-server/` |
| `yanivomc/linux-mcp-server:latest` | `linux-mcp-server/` |
| `yanivomc/event-watcher:latest` | `event-watcher/` |

> **Build for `linux/amd64`** (nodes are x86_64; arm64 from a Mac CrashLoops with
> `exec format error`): `docker buildx build --platform linux/amd64 ... --push`
> or `podman build --platform linux/amd64`. Deployments use `imagePullPolicy:
> Always`, so a pushed `:latest` rolls out on the next restart.
