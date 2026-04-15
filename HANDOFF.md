# ClawOps Workshop — Handoff Document

**Repo:** https://github.com/yanivomc/n8nWorkShop.git  
**Branch:** `main` (stable) | `feature/k8s-full-deploy` (merged)  
**Tags:** `v1.0.0` (current stable) | `v1.0.0-k8s-pre-merge` (pre-merge snapshot)

---

## Current Cluster

> Update these after each new cluster deployment

| | |
|---|---|
| **K8s Master IP** | `54.217.41.28` |
| **Terminal (ttyd)** | http://54.217.41.28:5000 |
| **VS Code** | http://54.217.41.28:5001 |
| **Ingress LB** | `a73d04515c35e448d9c7eafc7af42b1f-80b33ab936badce5.elb.eu-west-1.amazonaws.com` |
| **n8n** | http://`<LB>`/ |
| **Dashboard** | http://`<LB>`/dashboard/ |
| **Prometheus** | http://`<LB>`/prometheus |
| **Grafana** | http://`<LB>`/grafana (admin/workshop123) |
| **Alertmanager** | http://`<LB>`/alertmanager/ |

---

## Architecture

```
clawops namespace:   n8n, mcp-server, clawops-dashboard (PVCs for persistence)
workshop namespace:  target-app + linux-mcp-server (chaos targets)
monitoring namespace: prometheus + grafana + alertmanager (ClusterIP only)
ingress-nginx:       single nginx LB — one entry point for everything
```

**No Telegram. No ngrok.** — Dashboard chat replaces both.

---

## Bootstrap

```bash
# Fresh cluster
./bootstrap-k8s.sh run

# Interactive menu
./bootstrap-k8s.sh
# 1 = full bootstrap
# 2 = update configs (refresh all configmaps + restart pods)
# 3 = update ingress
# 4 = import workflows (prompts for n8n API key, saves it)
# 5 = show TOTP + QR code
# 6 = validate health checks
# 7 = delete ALL resources
```

**Most critical post-bootstrap check:**
```bash
kubectl describe configmap dashboard-config -n clawops | grep -E "PROMETHEUS|GRAFANA|ALERTMANAGER|MASTER_IP|N8N_URL"
```
All values must show real URLs — not `INJECT_*` placeholders.

---

## Namespace Layout

```
clawops/
  n8n                  — workflow automation
  mcp-server           — K8s + PromQL tools, SQLite incident store
                         ServiceAccount: mcp-server (in-cluster auth, no kubeconfig)
  clawops-dashboard    — incident command UI

workshop/
  target-app           — chaos scenarios + Prometheus metrics
  linux-mcp-server     — Linux diagnostic tools (NEW, port 8001)

monitoring/
  prometheus           — all ClusterIP, accessed via ingress /prometheus
  grafana              — /grafana (serve_from_sub_path + GF_SERVER_ROOT_URL)
  alertmanager         — /alertmanager/
```

---

## Ingress Rules

All in `k8s/ingress/ingress.yaml`. Applied via bootstrap or option 3.

| Rule | Namespace | Path | Backend |
|------|-----------|------|---------|
| workshop-ingress-n8n | clawops | `/` Prefix | n8n:5678 |
| workshop-ingress-dashboard | clawops | `/dashboard(/\|$)(.*)` + app-root | dashboard:80 |
| workshop-ingress-mcp | clawops | `/mcp(/\|$)(.*)` + rewrite | mcp-server:8000 |
| monitoring-ingress-prometheus | monitoring | `/prometheus` Prefix (no rewrite) | prometheus:9090 |
| monitoring-ingress-grafana | monitoring | `/grafana` Prefix (no rewrite) | grafana:80 |
| monitoring-ingress-alertmanager | monitoring | `/alertmanager(/\|$)(.*)` + rewrite | alertmanager:9093 |

**Key rules:**
- Prometheus and Grafana use **no rewrite** — they handle their own subpaths
- Dashboard uses `app-root` annotation for `/dashboard` → `/dashboard/` redirect

---

## ConfigMaps

### dashboard-config (clawops namespace)
Injected by bootstrap via sed. Critical fields:

```yaml
PROMETHEUS_URL:      http://<LB>/prometheus     # ingress path, NOT ClusterIP
GRAFANA_URL:         http://<LB>/grafana
ALERTMANAGER_URL:    http://<LB>/alertmanager/  # trailing slash required
N8N_URL:             http://<LB>/
MCP_URL:             http://<LB>/mcp            # browser nav link
MCP_INTERNAL_URL:    http://mcp-server.clawops.svc.cluster.local:8000  # server-side
MASTER_IP:           54.217.41.28               # auto-detected from EC2 metadata
MASTER_TERMINAL_PORT: 5000
MASTER_VSCODE_PORT:  5001
DASHBOARD_BASE_PATH: /dashboard
N8N_INTERNAL_URL:    http://n8n.clawops.svc.cluster.local:5678
S4_WEBHOOK_PATH:     /webhook/dashboard-chat
```

### n8n-config (clawops namespace)
```yaml
N8N_HOST:          <LB>
N8N_SECURE_COOKIE: "false"      # plain HTTP
WEBHOOK_URL:       http://<LB>/
```

---

## TOTP / Approval Gate

- **Secret stored in:** `kubectl get secret mcp-secrets -n clawops`
- **Reuse on re-run:** bootstrap reads existing secret, only regenerates on fresh cluster
- **Show QR:** `./bootstrap-k8s.sh` → option 5
- **After secret change:** MCP server must restart to pick up new TOTP
- **Approve format:** `/approve <6-digit-totp> <incident-key>` e.g. `/approve 123456 k42a`

---

## Workflows

| File | Trigger | Function |
|------|---------|----------|
| `s2-ai-agent-mcp.json` | n8n Chat Trigger | K8s + PromQL AI agent, n8n chat UI |
| `s2.5-linux-agent.json` | n8n Chat Trigger | K8s + Linux + PromQL agent |
| `s4-telegram-human-loop.json` | Webhook `/webhook/dashboard-chat` | Chat → AI → TOTP → kubectl-write |
| `s5-alert-intelligence.json` | Webhook `/webhook/prometheus-alert-s5` | Alert → AI enrich → dashboard chat |

**Import via:** `./bootstrap-k8s.sh` → option 4 (prompts for API key, saves to configmap)

**Import strips:** `id` and `versionId` fields — prevents duplicate rejection

---

## S4 Flow (Human Loop)

```
Student types in dashboard chat
  → POST /api/chat/message (dashboard)
  → POST n8n /webhook/dashboard-chat (S4)
  → Route Message: /approve or query?
  
Query path:
  → K8s Assistant (Gemini + kubectl_read + promql + lookup_incident)
  → Check Write Needed: SRE_ACTION detected?
  → Store Chat Incident: POST /incidents → gets real key from MCP
  → Send Approval Request to chat: "✅ /approve <totp> <key>"
  → Student approves → Fetch Incident Command → Execute Write
  
Approval path (/approve <totp> <key>):
  → Validate Approval: splits token + key
  → Use Key? → Fetch Incident Command (GET /incidents/<key>)
  → Check Pending Only: status must be "pending"
  → Execute Write: POST /tools/kubectl-write (strips "kubectl" prefix)
  → Mark Incident Resolved: PATCH /incidents/<key>
  → Send Execution Result to chat
```

---

## S5 Flow (Alert Intelligence)

```
Alertmanager → POST /webhook/prometheus-alert-s5 (n8n S5)
  → Dedup Filter
  → Set Prom URL
  → Extract Brief + Signal Plan
  → PromQL Enrichment + Confidence
  → Worth Escalating? (MEDIUM/HIGH only)
  → AI Agent (Gemini) — investigates with kubectl_read + promql
  → Store Incident → POST /incidents → key
  → Send to Dashboard Chat: POST /api/chat/send
    Content: "🚨 <alertname> detected!\n<AI analysis>\n🔐 /approve <totp> <key>"
```

Alertmanager webhook URL (internal K8s DNS):
`http://n8n.clawops.svc.cluster.local:5678/webhook/prometheus-alert-s5`

---

## MCP Server

**K8s MCP** (`mcp-server.clawops.svc.cluster.local:8000`)
- Runs with `mcp-server` ServiceAccount (in-cluster RBAC — no kubeconfig)
- RBAC: ClusterRole with read-all + write to workshop namespace
- SQLite DB at `/data/incidents.db` (PVC mounted)

**Linux MCP** (`linux-mcp-server.workshop.svc.cluster.local:8001`)  
- Safe read-only Linux commands via allowlist
- Commands: df, free, uptime, ps, netstat, ss, cat /proc/*, etc.
- Port 8001 (not 8000)

---

## Docker Images

```bash
# Build and push all images
cd mcp-server && docker build -t yanivomc/mcp-server:latest . && docker push yanivomc/mcp-server:latest
cd linux-mcp-server && docker build -t yanivomc/linux-mcp-server:latest . && docker push yanivomc/linux-mcp-server:latest
cd dashboard && docker build -t yanivomc/clawops-dashboard:latest . && docker push yanivomc/clawops-dashboard:latest
cd target-app && docker build -t yanivomc/target-app:latest . && docker push yanivomc/target-app:latest
```

---

## Key Lessons Learned

### n8n Code Node Restrictions
```
❌ fetch(), $httpRequest(), require('http') — all blocked in Code nodes
✅ Use HTTP Request nodes for all HTTP calls
✅ Use expressions in HTTP Request nodes to read from previous nodes
```

### n8n Workflow Import
```bash
# Always strip id/versionId before importing
python3 -c "
import json
with open('n8n-workflows/s4.json') as f: d=json.load(f)
d.pop('id', None); d.pop('versionId', None)
d['settings']={'executionOrder':'v1','saveManualExecutions':True}
with open('/tmp/wf.json','w') as f: json.dump(d,f)"
curl -s -X POST http://<N8N_IP>:5678/api/v1/workflows \
  -H "X-N8N-API-KEY: $KEY" -H "Content-Type: application/json" -d @/tmp/wf.json
```

### Dashboard Subpath
- `/config.js` must use relative path (not `/config.js`) — served at `/dashboard/config.js`
- All `/api/` calls use `API_BASE` prefix computed from `window.CLAWOPS_CONFIG.basePath`
- `DASHBOARD_BASE_PATH=/dashboard` injected from ConfigMap

### Monitoring Subpath
- Prometheus: `routePrefix: /prometheus` + NO nginx rewrite (handles itself)
- Grafana: `GF_SERVER_ROOT_URL + GF_SERVER_SERVE_FROM_SUB_PATH` as env vars + NO nginx rewrite
- Alertmanager: `routePrefix: /` + nginx rewrite strips `/alertmanager`

### TOTP
- Must be generated inside MCP pod (has pyotp): `kubectl exec -n clawops deployment/mcp-server -- python3 -c "import pyotp; print(pyotp.random_base32())"`
- Must be uppercase base32 — openssl fallback can produce lowercase (invalid)
- MCP pod must restart after secret change

---

## What's Done ✅
- Full K8s deployment — single bootstrap script
- All services on one ingress LB
- Dashboard with chat (SSE), chaos panel, incident audit
- S2: n8n chat AI agent ✅
- S2.5: Linux + K8s agent ✅
- S4: Dashboard chat human loop + TOTP ✅
- S5: Alert intelligence → dashboard chat ✅
- TOTP approval gate with incident keys
- Linux MCP server (student lab)
- Bootstrap menu with 7 options

## What's Next 🔜
1. S6–S8 sessions — not started
2. Slides for Day 2 (S5–S8 + capstone)
3. Lab docs lab-03 through lab-08
4. Merge linux-mcp into S4 system prompt (when lab complete)
