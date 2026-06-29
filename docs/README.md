# ClawOps Workshop — Documentation

**AI-Assisted Incident Command with Kubernetes, n8n, Gemini & the ClawOps dashboard**

---

## Table of Contents

| Document | Description |
|---|---|
| [Setup Guide](./setup-guide.md) | Full K8s setup via `bootstrap-k8s.sh`: install, configure n8n, import workflows, TOTP gate |
| [MCP Server](./mcp-server.md) | The execution layer — `kubectl-read`, `promql`, `kubectl-write` (TOTP-gated), incidents, audit logging |
| [S5 — Alert Intelligence](./workflow-s5.md) | Alert enrichment + confidence scoring → dashboard chat |
| [Handoff](../HANDOFF.md) | Current architecture, services, workflow status |
| [CLAUDE.md](../CLAUDE.md) | Full project context + implementation gotchas |

> **Archived (old Telegram / EC2 / Docker-Compose design):** `docs/_archive/`
> (S3, S4 Telegram docs), `labs/_archive/`, and `_archive/student-env/`.

---

## Architecture

```
Kubernetes cluster (kops, AWS, 2 nodes)
  clawops ns:    n8n | mcp-server | clawops-dashboard | event-watcher | linux-mcp-server
  workshop ns:   target-app (+ chaos-loader sidecar)
  monitoring ns: Prometheus | Grafana | Alertmanager  (all ClusterIP)

ONE nginx ingress LB:
  / → n8n   /dashboard/ → dashboard   /mcp/ → mcp-server
  /prometheus  /grafana  /alertmanager/  /events-admin/

Alert flow (workshop=true only):
  target-app chaos → Prometheus alert → Alertmanager
    → n8n S5 webhook → AI enriches (kubectl + promql via MCP)
    → dashboard chat (SSE) with incident key
    → engineer replies /approve <totp> <key>
    → S4 validates TOTP → MCP kubectl-write → confirmation back to chat
```

---

## Quick Start

```bash
git clone https://github.com/yanivomc/n8nWorkShop.git
cd n8nWorkShop
./bootstrap-k8s.sh run     # install everything (or run with no args for the menu)
```

Then: open `http://<LB>/` (n8n) to add the Gemini credential + an API key →
bootstrap option 4 to import workflows → option 5 for the TOTP secret →
drive it from `http://<LB>/dashboard/`. Full details in the
[Setup Guide](./setup-guide.md).

---

## Sessions

| # | Session | Trigger | Output | Status |
|---|---------|---------|--------|--------|
| S2 | AI Agent + MCP | n8n Chat UI | n8n chat | ✅ |
| S2.5 | Linux + K8s Agent | n8n Chat UI | n8n chat | ✅ |
| S4 | Dashboard Human Loop + TOTP | `/webhook/dashboard-chat` | dashboard chat | ✅ |
| S5 | Alert Intelligence | Alertmanager webhook | dashboard chat | ✅ |
| S6 | K8s Event Intelligence | event-watcher webhook | dashboard chat | ✅ |
| S8 | JWT-Secured Events | event-watcher + JWT | dashboard chat | ✅ |

> Use **S5 _or_ S6**, not both. **S8 = S6 + JWT** — use it instead of S6 to teach
> the security gate.
