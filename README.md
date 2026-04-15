# ClawOps — AI-Assisted Incident Command Workshop

**AI-Assisted Incident Command with Kubernetes, n8n, Gemini & ClawOps Dashboard**

8-hour hands-on workshop by DevopShift.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  K8s Cluster (kops, AWS, 2 nodes)                               │
│                                                                  │
│  Namespace: clawops                                              │
│    n8n             — workflow automation (port 5678)             │
│    mcp-server      — K8s + PromQL tools + incident store        │
│    clawops-dashboard — incident command UI + SSE chat           │
│                                                                  │
│  Namespace: workshop                                             │
│    target-app      — chaos scenarios + Prometheus metrics        │
│    linux-mcp-server — Linux OS diagnostic tools (port 8001)     │
│                                                                  │
│  Namespace: monitoring                                           │
│    Prometheus + Grafana + Alertmanager (ClusterIP only)         │
│                                                                  │
│  Namespace: ingress-nginx                                        │
│    ONE nginx LB → all services via path routing                 │
└─────────────────────────────────────────────────────────────────┘
         ↓ workshop=true alerts
Alertmanager → n8n S5 webhook (internal K8s DNS)
         ↓
n8n AI Agent → MCP Server → kubectl + promql
         ↓
Dashboard Chat (SSE real-time) → student approves
         ↓
TOTP-gated kubectl-write → cluster remediation
```

## URL Layout (ONE LB)

| Service | Path |
|---------|------|
| n8n | `http://<LB>/` |
| ClawOps Dashboard | `http://<LB>/dashboard/` |
| MCP Docs | `http://<LB>/mcp/docs` |
| Prometheus | `http://<LB>/prometheus` |
| Grafana | `http://<LB>/grafana` |
| Alertmanager | `http://<LB>/alertmanager/` |

---

## Quick Start

```bash
git clone https://github.com/yanivomc/n8nWorkShop.git
cd n8nWorkShop

# Full bootstrap (installs everything, no menu)
./bootstrap-k8s.sh run

# Or interactive menu
./bootstrap-k8s.sh
```

Bootstrap menu:
```
1) Full bootstrap     — install/upgrade everything
2) Update configs     — refresh configmaps + restart pods
3) Update ingress     — re-apply ingress rules
4) Import workflows   — push S2/S2.5/S4/S5 to n8n
5) Show TOTP / QR     — display secret for Authy
6) Validate           — run health checks
7) Delete ALL         — wipe everything, fresh start
```

---

## Sessions

| # | Session | Status |
|---|---------|--------|
| S2 | AI Agent + MCP (n8n chat UI) | ✅ READY |
| S2.5 | Linux + K8s Agent (lab extension) | ✅ READY |
| S4 | Dashboard Chat Human Loop + TOTP | ✅ READY |
| S5 | Alert Intelligence → Dashboard Chat | ✅ READY |
| S6–S8 | — | ❌ TODO |

---

## Repository Structure

```
n8nWorkShop/
├── bootstrap-k8s.sh              # Single-script full deployment
├── k8s/
│   ├── clawops/                  # n8n, mcp-server, dashboard manifests
│   │   ├── namespace.yaml
│   │   ├── n8n/
│   │   ├── mcp-server/           # Includes rbac.yaml (ServiceAccount)
│   │   └── dashboard/
│   ├── workshop/                 # target-app, linux-mcp-server
│   │   ├── namespace.yaml
│   │   ├── target-app/
│   │   └── linux-mcp-server/
│   ├── ingress/
│   │   ├── ingress-nginx-values.yaml
│   │   └── ingress.yaml          # All path rules, one LB
│   └── monitoring/
│       └── prometheus-values.yaml  # ClusterIP services + alert rules
├── mcp-server/
│   └── server.py                 # kubectl-read, promql, kubectl-write, incidents
├── linux-mcp-server/             # Linux diagnostic tools MCP
│   ├── server.py
│   ├── requirements.txt
│   └── Dockerfile
├── target-app/                   # Chaos engineering app
├── dashboard/
│   ├── app.py                    # FastAPI — SSE chat, chaos proxy, incidents
│   └── index.html                # Dashboard UI
├── n8n-workflows/
│   ├── s2-ai-agent-mcp.json
│   ├── s2.5-linux-agent.json     # Linux + K8s agent
│   ├── s4-telegram-human-loop.json
│   └── s5-alert-intelligence.json
└── labs/
    ├── lab-linux-mcp-server.md   # Student lab spec
    └── linux-mcp-agent-prompt.md # AI prompt for students
```

---

## Docker Images

| Image | Description |
|-------|-------------|
| `yanivomc/target-app:latest` | Chaos scenarios + metrics |
| `yanivomc/clawops-dashboard:latest` | Dashboard + SSE chat + API |
| `yanivomc/mcp-server:latest` | K8s + PromQL tools + incident store |
| `yanivomc/linux-mcp-server:latest` | Linux diagnostic tools |

---

## MCP Server Endpoints

**K8s MCP** (`http://mcp-server.clawops.svc.cluster.local:8000`)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/tools/kubectl-read` | None | Read-only kubectl commands |
| POST | `/tools/promql` | None | PromQL queries → Prometheus |
| POST | `/tools/kubectl-write` | TOTP | Write kubectl (scale, restart, etc.) |
| POST | `/incidents` | None | Create incident → returns 4-char key |
| GET | `/incidents/{key}` | None | Get incident by key |
| PATCH | `/incidents/{key}` | None | Update status |
| GET | `/incidents` | None | List all incidents |

**Linux MCP** (`http://linux-mcp-server.workshop.svc.cluster.local:8001`)

| Method | Path | Description |
|--------|------|-------------|
| POST | `/tools/linux-read` | df, free, ps, netstat, uptime, etc. |

---

## Dashboard API (`http://<LB>/dashboard/`)

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/register` | target-app registers on startup |
| GET | `/api/instances` | List registered pods + status |
| POST | `/api/chaos/{id}/action` | Proxy chaos trigger |
| POST | `/api/chat/send` | n8n → dashboard chat |
| POST | `/api/chat/message` | Student → n8n S4 webhook |
| GET | `/api/chat/stream` | SSE real-time chat |
| GET | `/api/incidents` | Proxy from MCP |
| GET | `/config.js` | Runtime URLs from ConfigMap |

---

## Incident Flow

```
Alert fires → Alertmanager → n8n S5
  → AI enriches → POST /incidents → key "k42a"
  → POST /api/chat/send → dashboard chat
  → Student types: /approve 123456 k42a
  → S4 validates TOTP → executes kubectl-write
  → Result back to chat → incident resolved
```

---

## Tags

| Tag | Description |
|-----|-------------|
| `v1.0.0` | First stable K8s full deployment |
| `v1.0.0-k8s-pre-merge` | Feature branch snapshot |
