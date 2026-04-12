# CLAUDE.md — ClawOps Workshop AI Context

This file gives AI assistants (Claude, Cursor, Copilot, etc.) full context about this project so you can help students build, extend, debug, and learn without needing lengthy explanations.

---

## What This Project Is

**ClawOps** is an 8-hour hands-on DevOps workshop teaching AI-assisted incident command. Students learn how to wire together Kubernetes, Prometheus, n8n, and an AI agent (Gemini) so that when something breaks in production, the system detects it, investigates it, and asks a human to approve the fix — all through Telegram.

**Target audience:** DevOps/SRE engineers at Radware. Intermediate K8s knowledge assumed.

**Core thesis:** "You don't build incident response workflows manually anymore — you describe what you want and AI helps you build it. But you still own the architecture and the approval gate."

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  K8s Cluster (kops, AWS, 2 nodes)                   │
│  Namespace: workshop                                 │
│                                                      │
│  clawops-dashboard (FastAPI, LB:80)                 │
│    /api/register   ← target-app registers here      │
│    /api/instances  ← browser polls this             │
│    /api/chaos/{id}/action/{scenario} ← proxy        │
│    /config.js      ← env-injected URLs              │
│                                                      │
│  target-app (FastAPI, NodePort:30080)                │
│    /chaos/cpu  /chaos/memory  /chaos/crash           │
│    /chaos/error-loop  /chaos/all  /chaos/status      │
│    /metrics  (Prometheus format)                     │
│    → registers to dashboard on startup               │
│    → background loop reconnects if dashboard dies    │
│                                                      │
│  Prometheus + Grafana + Alertmanager (AWS LBs)      │
│    Alert rules: TargetAppCPUStress,                  │
│                 TargetAppMemoryLeak,                 │
│                 TargetAppCrashLooping, etc.          │
│    Only workshop="true" alerts → Alertmanager → n8n │
└─────────────────────────────────────────────────────┘
         ↓ alerts (workshop=true only)
┌─────────────────────────────────────────────────────┐
│  n8n (Docker on EC2, port 5678)                     │
│                                                      │
│  S2: Manual Trigger → AI Agent (Gemini) → MCP       │
│  S3: Alert Webhook → LLM Parser → AI Agent → TG     │
│  S4: Telegram Bot → K8s Assistant → TOTP Gate       │
│  S5: Alert Intelligence (enrich before act) — TODO  │
└─────────────────────────────────────────────────────┘
         ↓ HTTP calls
┌─────────────────────────────────────────────────────┐
│  MCP Server (Docker, EC2:8000)                      │
│  /tools/kubectl-read  → free                        │
│  /tools/promql        → free                        │
│  /tools/kubectl-write → TOTP 2FA gated              │
│  /discovery           → lists target-app pods       │
└─────────────────────────────────────────────────────┘
         ↓
Telegram Bot (on-call engineer interface)
```

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Orchestration | Kubernetes (kops on AWS) |
| Workflow automation | n8n (self-hosted) |
| AI | Gemini 2.5-flash via n8n LangChain nodes |
| Monitoring | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) |
| Notifications | Telegram Bot API |
| MCP Server | FastAPI + pyotp + kubectl |
| Dashboard | FastAPI (serves static HTML + REST API) |
| Target App | FastAPI (chaos scenarios + Prometheus metrics) |
| 2FA | TOTP (pyotp, Google Authenticator compatible) |
| Infra as code | Helm, kubectl, kops |

---

## Repository Structure

```
n8nWorkShop/
├── student-env/
│   ├── setup.sh              # 12-option setup menu (students run this)
│   ├── docker-compose.yml    # n8n + MCP server
│   └── .env.example
├── mcp-server/
│   └── server.py             # FastAPI MCP — kubectl-read, promql, kubectl-write
├── target-app/
│   ├── main.py               # FastAPI entrypoint + background registration loop
│   ├── config.py             # logging + env vars
│   ├── routes/
│   │   ├── chaos.py          # /chaos/* endpoints
│   │   ├── health.py         # /health /ready /info
│   │   └── metrics.py        # /metrics (Prometheus format)
│   ├── chaos/
│   │   ├── cpu.py            # thread-based CPU burn
│   │   ├── memory.py         # incremental memory allocation
│   │   └── crash.py          # SIGKILL + probe failure
│   └── k8s/
│       ├── deployment.yaml   # Deployment + NodePort + LB services
│       └── servicemonitor.yaml
├── dashboard/
│   ├── app.py                # FastAPI: /api/register /api/instances /api/chaos proxy
│   ├── index.html            # Dashboard UI (vanilla JS, no framework)
│   ├── requirements.txt
│   ├── Dockerfile
│   └── k8s/
│       └── dashboard.yaml    # Deployment + LB + ClusterIP services + ConfigMap
├── k8s/
│   ├── monitoring/
│   │   ├── prometheus-values.yaml  # Helm values — LBs, alerting, rules
│   │   └── target-app-alerts.yaml  # PrometheusRule for chaos scenarios
│   └── scenarios/
│       ├── 01-crashloop/     # CrashLoopBackOff scenario
│       ├── 02-oom-kill/      # OOM kill scenario
│       ├── 03-pending-pods/
│       ├── 04-failed-deployment/
│       ├── 05-flapping-alert/
│       └── force-alert.sh    # Send fake Alertmanager payloads
├── n8n-workflows/
│   ├── s2-ai-agent-mcp.json
│   ├── s3-alert-webhook-telegram.json
│   └── s4-telegram-human-loop.json
├── labs/
│   ├── lab-01-n8n-setup.md
│   └── lab-02-ai-agent-mcp.md
└── docs/
    ├── README.md             # TOC + architecture + session status
    ├── setup-guide.md        # Full setup walkthrough
    ├── mcp-server.md         # MCP endpoints, TOTP, audit logging
    ├── workflow-s3.md        # S3 nodes explained
    └── workflow-s4.md        # S4 TOTP flow explained
```

---

## Setup (Student Flow)

```bash
git clone https://github.com/yanivomc/n8nWorkShop.git
cd n8nWorkShop/student-env && cp .env.example .env
./setup.sh
```

Menu order for a fresh machine:
1. Configure cluster (IP + kubeconfig)
2. Configure API keys (Gemini, Telegram, TOTP, ngrok)
3. Install Prometheus + Grafana
4. Start stack (n8n + MCP)
5. Start ngrok (for Telegram Trigger HTTPS)
6. Deploy Dashboard + Target App to K8s
7. Stop stack
8. Validate full setup
9. Test Telegram bot
10. Show status
11. Generate credentials file
12. Clean K8s workshop resources

---

## Sessions Overview

### S2 — AI Agent + MCP (60 min) ✅
Students connect n8n to Gemini and the MCP server. Ask the AI about cluster state in plain English. The AI calls `kubectl-read` and `promql` tools automatically.

**Key learning:** LLM as a K8s operator — describe what you want, not how to do it.

### S3 — Alert Webhook + AI Triage (60 min) ✅
Trigger a chaos scenario on the dashboard → Prometheus detects it → Alertmanager sends to n8n → LLM parses the alert → AI Agent investigates → Telegram notification.

**Key learning:** LLM as semantic alert parser (works for any K8s resource, not hardcoded field names).

### S4 — Telegram Human Loop (60 min) ✅
Conversational K8s assistant via Telegram. When AI suggests a write action, it prompts for TOTP code. Human approves → MCP executes.

**Key learning:** Human-in-the-loop approval gate. AI diagnoses, human approves, MCP executes.

### S5 — Alert Intelligence (60 min) ❌ TODO
Upgrade S3: don't react to single signals. Enrich first — check duration, correlate CPU + memory + restarts, confidence scoring. Only escalate if multiple signals agree.

**Key learning:** "Never act on a single signal." Correlation before action.

### S6 — Stateful Incident Handling (45 min) ❌ TODO
Flapping detection, alert suppression, incident deduplication. Don't send 50 Telegrams for the same issue.

### S7 — Controlled Remediation (45 min) ❌ TODO
Canary restarts, rollback logic, audit trail. Safe write operations with verification.

### S8 — End-to-End Capstone (55 min) ❌ TODO
Students build a complete incident response workflow from scratch using AI assistance. Full flow: detect → investigate → notify → approve → fix → verify.

---

## Lab Pattern (How Labs Work)

Each lab follows: **Trigger → Observe → Modify → Extend**

1. **Trigger** — use the dashboard to fire a chaos scenario
2. **Observe** — watch it flow through Prometheus → Alertmanager → n8n → Telegram
3. **Modify** — change the AI prompt, add a condition, adjust a threshold in n8n
4. **Extend** — describe a new behavior to the AI and let it help you build it

Students do NOT build from scratch. They have a working system and learn by operating and modifying it.

---

## Common Tasks for AI Assistants

### "Help me add a new chaos scenario"
Add a new endpoint to `target-app/routes/chaos.py`, add the chaos logic in `target-app/chaos/`, add a button to `dashboard/index.html`, add a Prometheus alert rule to `k8s/monitoring/prometheus-values.yaml`.

### "Help me modify the S3 AI prompt"
Open `n8n-workflows/s3-alert-webhook-telegram.json`, find the `AI Agent` node, edit the `systemMessage` field.

### "Help me add a new n8n workflow"
Export from n8n UI, strip extra fields (see HANDOFF.md import command), commit to `n8n-workflows/`.

### "Help me add a new alert rule"
Add to `k8s/monitoring/prometheus-values.yaml` under `additionalPrometheusRulesMap.workshop-alerts.groups`. Must include `workshop: "true"` label.

### "Help me debug why an alert isn't firing"
```bash
# Check metric exists
curl -s "<PROM_URL>/api/v1/query?query=<metric_name>" | python3 -m json.tool

# Check rule loaded
curl -s "<PROM_URL>/api/v1/rules" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(r['name'],r['state']) for g in d['data']['groups'] for r in g['rules'] if '<RuleName>' in r['name']]"
```

### "Help me rebuild and deploy"
```bash
# Dashboard
cd dashboard && docker build -t yanivomc/clawops-dashboard:latest . && docker push yanivomc/clawops-dashboard:latest
kubectl rollout restart deployment/clawops-dashboard -n workshop

# Target app
cd target-app && docker build -t yanivomc/target-app:latest . && docker push yanivomc/target-app:latest
kubectl rollout restart deployment/target-app -n workshop
```

---

## Key Design Decisions (Teach These)

### LLM as semantic parser, not hardcoded field extractor
```python
# BAD — breaks on schema changes
namespace = alert["labels"]["namespace"]

# GOOD — LLM reads semantically
prompt = f"Parse this Alertmanager payload and extract: resource_type, namespace, symptom, recommended_kubectl_commands. Payload: {raw_payload}"
```

### `SRE_ACTION:` keyword avoids Gemini safety refusals
Gemini refuses "write", "execute", "approve" in command contexts. Neutral `SRE_ACTION:` is treated as structured output, not a command.

### TOTP over static tokens
Static tokens never expire. TOTP codes expire every 30s — even if intercepted, they're useless.

### Server-side chaos proxy
Browser → Dashboard API → target-app (internal K8s DNS). Browser never reaches target-app directly, avoids CORS/firewall issues.

### Filter at the router, not the consumer
Only `workshop="true"` alerts reach n8n. System noise silently swallowed by null-receiver in Alertmanager.

---

## Docker Images
- `yanivomc/target-app:latest` — chaos app
- `yanivomc/clawops-dashboard:latest` — dashboard + API
- `yanivomc/student-env-mcp-server:latest` — MCP server (built by docker-compose)

---

## Environment Variables

### target-app
| Var | Description |
|-----|-------------|
| `DASHBOARD_URL` | ClusterIP URL for registration (set in deployment.yaml) |
| `SKIP_REGISTRATION` | Set to `true` to disable registration |
| `POD_NAME` | Injected by K8s downward API |
| `POD_NAMESPACE` | Injected by K8s downward API |

### dashboard
| Var | Description |
|-----|-------------|
| `PROMETHEUS_URL` | Prometheus LB URL |
| `GRAFANA_URL` | Grafana LB URL |
| `ALERTMANAGER_URL` | Alertmanager LB URL |
| `N8N_URL` | n8n EC2 URL |

### MCP server
| Var | Description |
|-----|-------------|
| `PROMETHEUS_URL` | For PromQL queries |
| `TOTP_SECRET` | Base32 secret for 2FA |
| `WRITE_APPROVAL_TOKEN` | Fallback static token |
| `KUBECONFIG` | Path to kubeconfig |
