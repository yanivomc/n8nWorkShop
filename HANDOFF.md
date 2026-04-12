# Workshop Build Handoff — n8n DevOps Automation

## Project
8-hour hands-on workshop teaching AI-assisted incident command using n8n, Gemini, MCP server, Kubernetes, Prometheus/Grafana, and Telegram.

**Repo:** https://github.com/yanivomc/n8nWorkShop.git

---

## Current EC2
| | |
|---|---|
| **IP** | `3.251.68.65` |
| **Terminal (ttyd)** | http://3.251.68.65:5000 |
| **VS Code** | http://3.251.68.65:5001 |
| **n8n** | http://3.251.68.65:5678 (yanivomc@gmail.com / Nuva3131) |
| **MCP Server** | http://3.251.68.65:8000/docs |
| **n8n API Key** | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZmZlYWNhMS0xZDk3LTRhYTQtYWFkZi1lZTg4YWFmOTkwZjAiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwianRpIjoiOGQxMGY3MTItMzdlOC00M2EzLTlhYzctM2FiY2QwOWZiMjFmIiwiaWF0IjoxNzc1OTg5Njk5LCJleHAiOjE3ODExMjUyMDB9.tNt8tl9RUh0K-KjqOAgN1Tl3CFlBmX0j6hc1Ehb2O-c` |
| **Prometheus LB** | http://a26eacb3a567844368716083b871dd5f-672656453.eu-west-1.elb.amazonaws.com:9090 |
| **Grafana LB** | http://ae58db3f2c8dc44330e384a01796b8d5-1124178425.eu-west-1.elb.amazonaws.com (admin / workshop123) |
| **Dashboard LB** | http://a6f30eddf0aa5458e911a4e91fe89ac8-df1e1a0cfad3220c.elb.eu-west-1.amazonaws.com |
| **Alertmanager LB** | http://ac54d97487bf34e7381e31a4b3a966a4-1542871555.eu-west-1.elb.amazonaws.com:9093 |
| **ngrok** | https://quadruplex-goofily-colton.ngrok-free.dev |

---

## Architecture
```
K8s Cluster (kops, 2 nodes, v1.29) + Prometheus + Grafana (AWS LBs)
  ↓ alerts & events (webhook → ngrok → n8n)
n8n (AI Agent node — orchestration + human loop)
  ↓ calls MCP Server HTTP endpoints
MCP Server (Docker, same EC2) — tools:
  kubectl-read  → free
  promql        → free (forwards to Prometheus LB)
  kubectl-write → GATED: requires TOTP
  /incidents    → SQLite audit store (POST/GET/PATCH/list)
  ↓
Telegram Bot (field/on-call) + n8n Chat (in-office/browser)
```

---

## CRITICAL n8n Rules (learned the hard way)

### Code Node Sandbox Restrictions
n8n Code nodes run in a restricted sandbox. The following are ALL BLOCKED:
- ❌ `fetch()` — not defined
- ❌ `$httpRequest()` — not defined
- ❌ `$helpers.httpRequest()` — not defined
- ❌ `require('http')`, `require('https')` — blocked
- ❌ `$env.MY_VAR` — env vars denied

**✅ For HTTP calls from workflows: use a dedicated HTTP Request node**
**✅ For env vars: inject via Set node or pass through from trigger payload**

### Tool Nodes (toolHttpRequest)
For AI Agent tool nodes using `specifyBody: json`:
- Use `jsonBody: ={"query": "{query}"}` format (matches S3 working config)
- Tool nodes CAN make HTTP calls — only Code nodes are sandboxed
- `toolDescription` must be in **Fixed** mode, not Expression

### Gemini Model
- Always use `gemini-2.5-flash` — gemini-2.0 no longer exists
- Model is set in the UI credential, not in JSON

### Workflow Import
Always strip extra settings before import:
```python
d['settings'] = {'executionOrder':'v1','saveManualExecutions':True,
                 'saveDataErrorExecution':'all','saveDataSuccessExecution':'all'}
```

---

## Repo Structure
```
n8nWorkShop/
├── mcp-server/           # FastAPI, tools + incident store, Dockerfile
├── target-app/           # FastAPI chaos app
│   ├── chaos/
│   │   ├── cpu.py        # CPU stress
│   │   ├── memory.py     # Memory leak
│   │   ├── crash.py      # Crash + error loop
│   │   └── errors.py     # Error rate + latency injection (NEW)
│   └── routes/
│       ├── chaos.py      # All chaos endpoints incl. /error-rate /latency
│       └── metrics.py    # Prometheus metrics (all target_chaos_*)
├── dashboard/            # FastAPI + static HTML incident command UI
│   ├── app.py            # API proxy + /api/incidents endpoint
│   └── index.html        # Dashboard UI with sessionStorage persistence
├── k8s/
│   ├── monitoring/       # prometheus-values.yaml (all alert rules)
│   └── scenarios/
│       └── force-s5-test.sh  # Test S5 via webhook-test endpoint
├── student-env/
│   ├── docker-compose.yml   # n8n + mcp-server + volumes
│   ├── .env.example
│   └── setup.sh             # 9-option menu
├── n8n-workflows/
│   ├── s2-ai-agent-mcp.json
│   ├── s3-alert-webhook-telegram.json
│   ├── s4-telegram-human-loop.json
│   └── s5-alert-intelligence.json
└── labs/
    ├── lab-01-n8n-setup.md
    └── lab-02-ai-agent-mcp.md
```

---

## Session Status
| # | Session | Status |
|---|---------|--------|
| S2 | AI Agent + MCP | ✅ READY |
| S3 | Alert Webhook | ⛔ DEACTIVATED (replaced by S5) |
| S4 | Telegram + TOTP human loop | ✅ READY |
| S5 | Alert Intelligence | ✅ STABLE |
| S6–S8 | — | ❌ TODO |

---

## S5 Architecture (Alert Intelligence)
```
Alertmanager Webhook
  → Dedup Filter (disabled for testing, run_id label bypasses)
  → Set Prom URL (extracts promUrl from generatorURL, passes alert+body)
  → Extract Brief + Signal Plan (reads alert from body.alerts[0] fallback)
  → PromQL Enrichment + Confidence (PASSTHROUGH — no HTTP, hardcodes MEDIUM)
  → Worth Escalating? (IF node — MEDIUM/HIGH passes, LOW logs only)
  → AI Agent (Gemini) — investigates using kubectl_read + promql tools
  → Store Incident (HTTP Request → POST /incidents on MCP → returns key)
  → Format Telegram Message (reads key from Store Incident node)
  → Send to Telegram
```

### S5 System Prompt (SRE Methodology)
- Layer-by-layer investigation (TRAFFIC→SCHEDULING→RUNTIME→APPLICATION→DEPENDENCIES)
- Treats chaos scenarios as REAL production incidents
- Exact metric names: `target_chaos_cpu_active`, `target_chaos_memory_active`, `target_chaos_memory_bytes`, `target_chaos_error_active`, `target_chaos_latency_active`
- OUTPUT FORMAT: Hypothesis trail, Fault Location, Root Cause, Confidence, `SRE_ACTION: kubectl <command>`

### S5 Telegram Message Format
```
⚠️ INCIDENT DETECTED #k42a
━━━━━━━━━━━━━━━━━━━━
📍 pod / namespace
🏷 AlertName — 🔥 FIRING
⏱ Duration
🔍 Confidence: 🔴 HIGH

🧠 AI Assessment
[Hypothesis trail + root cause]

✅ Recommended Action
kubectl rollout restart deployment/target-app -n workshop

💬 Reply: /approve <totp> k42a
━━━━━━━━━━━━━━━━━━━━
🕐 timestamp UTC
```

### Incident Key Flow
1. S5 fires → `POST /incidents` → MCP stores in SQLite → returns 4-char key (e.g. `k42a`)
2. S5 sends Telegram with `💬 /approve <totp> k42a`
3. Engineer replies `/approve 123456 k42a`
4. S4 K8s Assistant looks up command by key → validates TOTP → executes via kubectl_write
5. Dashboard incident audit panel shows all incidents from `GET /incidents`

---

## Chaos Scenarios
| Scenario | Endpoint | Alert | Metrics |
|---|---|---|---|
| CPU Spike | POST /chaos/cpu | TargetAppCPUStress | target_chaos_cpu_active |
| CPU Sustained | POST /chaos/cpu (2 cores, 300s) | TargetAppCPUStress | target_chaos_cpu_active |
| Memory Leak | POST /chaos/memory | TargetAppMemoryLeak, TargetAppMemoryCritical | target_chaos_memory_active, target_chaos_memory_bytes |
| Error Rate | POST /chaos/error-rate | TargetAppHighErrorRate | target_chaos_error_active, target_chaos_error_rate |
| High Latency | POST /chaos/latency | TargetAppHighLatency | target_chaos_latency_active, target_chaos_latency_ms |
| Crash Pod | POST /chaos/crash | — | kube_pod_container_status_restarts_total |

---

## MCP Server Endpoints
```
POST /tools/kubectl-read   → free read-only kubectl
POST /tools/promql         → any PromQL, forwards to Prometheus LB
POST /tools/kubectl-write  → TOTP gated write operations
POST /incidents            → create incident {alertname, namespace, pod, command} → returns {key}
GET  /incidents/{key}      → get incident by key
PATCH /incidents/{key}     → update status {status: approved|resolved}
GET  /incidents            → list all incidents (limit param)
GET  /discovery            → list all tools
```

---

## Docker Images
- `yanivomc/target-app:latest`
- `yanivomc/clawops-dashboard:latest`
- MCP server built locally by docker-compose

---

## Key Commands
```bash
# Rebuild and deploy target-app
cd ~/n8nWorkShop && git pull
cd target-app && docker build -t yanivomc/target-app:latest . && docker push yanivomc/target-app:latest
kubectl rollout restart deployment/target-app -n workshop

# Rebuild dashboard
cd dashboard && docker build -t yanivomc/clawops-dashboard:latest . && docker push yanivomc/clawops-dashboard:latest
kubectl rollout restart deployment/clawops-dashboard -n workshop

# Rebuild MCP
cd ~/n8nWorkShop/student-env && docker compose up -d --build mcp-server

# Helm upgrade (alert rules)
source student-env/.env
sed "s|EC2_PUBLIC_IP_PLACEHOLDER|${EC2_PUBLIC_IP}|g" k8s/monitoring/prometheus-values.yaml > /tmp/prom-values.yaml
helm upgrade monitoring prometheus-community/kube-prometheus-stack -n monitoring -f /tmp/prom-values.yaml

# Import workflow
N8N_KEY="<api_key>"
python3 -c "
import json
with open('n8n-workflows/s5-alert-intelligence.json') as f: d=json.load(f)
d['settings']={'executionOrder':'v1','saveManualExecutions':True,'saveDataErrorExecution':'all','saveDataSuccessExecution':'all'}
with open('/tmp/wf.json','w') as f: json.dump(d,f)
" && curl -s -X POST http://localhost:5678/api/v1/workflows \
  -H "X-N8N-API-KEY: $N8N_KEY" -H "Content-Type: application/json" \
  -d @/tmp/wf.json | python3 -c "import sys,json; d=json.load(sys.stdin); print('ID:', d.get('id','ERR'))"

# Test S5 without real alert (needs "Listen for test event" active in n8n)
./k8s/scenarios/force-s5-test.sh TargetAppCPUStress test-$(date +%s)

# Check incidents in MCP
curl -s http://localhost:8000/incidents | python3 -m json.tool
```

---

## Known Gotchas
- **n8n Code nodes cannot make HTTP calls** — use HTTP Request nodes instead
- `N8N_API_KEY` env var must be exported each shell session
- `PROMETHEUS_URL` in `.env` must match live ELB
- n8n API PUT/POST rejects extra settings fields — strip before import
- Tool nodes (`toolHttpRequest`) cannot be tested standalone — only via AI Agent
- `toolDescription` must be in **Fixed** mode, not Expression mode
- Gemini model: always use `gemini-2.5-flash` (2.0 deprecated)
- MCP incidents DB at `/data/incidents.db` inside mcp-server container (Docker volume `mcp_data`)
- Dashboard fetchJ uses relative URLs (`/api/...`) — direct `http://mcp-server:8000` not reachable from browser
- sessionStorage persists logs/instances within browser tab session (clears on tab close)
- Dedup Filter disabled for testing — re-enable for production (10min window, run_id label bypasses)

---

## What's Done ✅
- Full chaos engineering app (CPU, memory, crash, error rate, latency)
- Dashboard with chaos buttons, alert panel, incident audit, sessionStorage persistence
- Prometheus alert rules for all 6 scenarios
- MCP server with kubectl + promql tools + SQLite incident store
- S2: Manual AI Agent ✅
- S4: Telegram bidirectional + TOTP ✅
- S5: Alert Intelligence — SRE layer methodology, incident keys, audit trail ✅

## What's Next 🔜
1. **Test S4+S5 approve flow end-to-end** with incident key
2. **Re-enable Dedup** after testing complete
3. **S6–S8** sessions — not started
4. **Lab docs** lab-03 through lab-08
5. **Slides** — after all workflows validated
