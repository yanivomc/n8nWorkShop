# n8n DevOps Workshop — Documentation

**AI-Assisted Incident Command with Kubernetes, n8n, Gemini & Telegram**

---

## Table of Contents

| Document | Description |
|---|---|
| [Setup Guide](./setup-guide.md) | Full setup from scratch: EC2, Docker, n8n, ngrok, credentials |
| [MCP Server](./mcp-server.md) | How the MCP server works, all endpoints, TOTP 2FA, audit logging |
| [S3 — Alert Webhook + AI Triage](./workflow-s3.md) | Alert pipeline: Alertmanager → LLM Parser → AI Agent → Telegram |
| [S4 — Telegram Human Loop](./workflow-s4.md) | Conversational K8s assistant + approval gate with TOTP 2FA |
| [Handoff](../HANDOFF.md) | Session state, credentials, what's done, what's next |

---

## Architecture Overview

```
Kubernetes Cluster (kops, 2 nodes, v1.29)
  + Prometheus + Grafana (AWS LoadBalancers)
  + Alertmanager → n8n webhook (workshop alerts only)
          ↓
n8n (Docker on EC2)
  S3: Alert Webhook → LLM Parser → AI Agent → Telegram
  S4: Telegram Bot → K8s Assistant → Approval Gate
          ↓
MCP Server (Docker, same EC2)
  kubectl-read  → free
  promql        → free
  kubectl-write → GATED: TOTP 2FA required
          ↓
Telegram Bot (field interface for on-call engineers)
```

---

## Quick Start Checklist

```
□ 1. EC2 running, Docker installed
□ 2. git clone https://github.com/yanivomc/n8nWorkShop.git
□ 3. cd student-env && cp .env.example .env
□ 4. ./setup.sh → option 3  (configure API keys + generate TOTP secret)
□ 5. ./setup.sh → option 4  (install Prometheus + Grafana)
□ 6. ./setup.sh → option 5  (start n8n + MCP)
□ 7. ./setup.sh → option 10 (start ngrok for Telegram webhook)
□ 8. Open n8n → add Gemini + Telegram credentials
□ 9. Import S3 + S4 workflows
□ 10. Activate workflows → test
```

---

## Sessions Status

| # | Session | Status |
|---|---------|--------|
| S1 | Security Foundation | ❌ not built |
| S2 | n8n AI Agent + Gemini + MCP | ✅ READY |
| S3 | Alert Webhook + AI Triage + Telegram | ✅ READY |
| S4 | Telegram Human Loop + TOTP Approval | 🔜 95% |
| S5 | Prometheus Alert Intelligence | ❌ |
| S6 | Stateful Incident Handling | ❌ |
| S7 | Controlled Remediation | ❌ |
| S8 | End-to-End Capstone | ❌ |
