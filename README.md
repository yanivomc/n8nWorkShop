# n8n DevOps Automation Workshop

**AI-Assisted Incident Command with Kubernetes, n8n AI Agent, Gemini & Telegram**

8-hour hands-on workshop by DevopShift.

## Architecture

```
Kubernetes Cluster (kops, 2 nodes)  /  Prometheus  /  Grafana
        ↓  alerts & events (webhook)
n8n  (AI Agent node — orchestration + human loop)
        ↓  calls MCP Server HTTP endpoints
MCP Server  (Docker, same EC2 as n8n)
    run_kubectl_read(cmd)   — agent calls freely
    run_promql(query)       — agent calls freely
    run_kubectl_write(cmd)  — GATED: human must approve via Telegram
        ↓  structured diagnosis + recommendation
Telegram Bot  (reactive alerts + conversational queries)
        ↑  YES / NO / INFO / free text
Human Decision → n8n calls MCP write tool → Audit Log
```

## Student Environment

Each student gets:
- 2-node private Kubernetes cluster (kops)
- EC2 instance with Docker engine
- Browser-based terminal + VS Code Server (no SSH needed)
- n8n + MCP Server running via docker-compose

## Sessions

| # | Session | Duration |
|---|---------|----------|
| S1 | Security Foundation | 60 min |
| S2 | n8n AI Agent + Gemini + MCP | 60 min | ✅ READY |
| S3 | Reacting to Kubernetes Events | 60 min | ✅ READY |
| S4 | The Telegram Human Loop | 60 min |
| S5 | Prometheus Alert Intelligence | 60 min |
| S6 | Stateful Incident Handling | 45 min |
| S7 | Controlled Remediation with Approval Gates | 45 min |
| S8 | End-to-End Capstone | 55 min |

## Quick Start (Student)

```bash
git clone <repo-url>
cd n8nWorkShop/student-env
cp .env.example .env
# fill in GEMINI_API_KEY and TELEGRAM_BOT_TOKEN
docker-compose up -d
```

Then open http://localhost:5678 for n8n and http://localhost:8000/docs for MCP server.

## Repository Structure

```
mcp-server/       # FastAPI MCP server — 3 tools: read, promql, write(gated)
k8s/              # Cluster setup, monitoring, lab failure scenarios
student-env/      # docker-compose + .env for student EC2
n8n-workflows/    # Exported n8n workflow JSONs per session
labs/             # Step-by-step lab guides
infrastructure/   # Terraform + bootstrap scripts
```

