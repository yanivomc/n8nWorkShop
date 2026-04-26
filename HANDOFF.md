# ClawOps n8n Workshop — Handoff Document
**Last updated:** 2026-04-26  
**Repo:** https://github.com/yanivomc/n8nWorkShop  
**Branch:** main

---

## Architecture

```
Namespaces:
  clawops:   n8n | mcp-server | clawops-dashboard | event-watcher | linux-mcp-server
  workshop:  target-app (+ chaos-loader sidecar)
  monitoring: prometheus | grafana | alertmanager
  ingress-nginx: nginx LB

Ingress (single LB):
  /           → n8n:5678
  /dashboard/ → clawops-dashboard:80
  /mcp/       → mcp-server:8000
  /prometheus → prometheus:9090
  /grafana    → grafana:3000
  /alertmanager/ → alertmanager:9093
  /events-admin/ → event-watcher:8002  (clawops ns)
```

---

## Services

### clawops-dashboard
- Port 80 | image: `yanivomc/clawops-dashboard:latest`
- Tabs: DASHBOARD (chaos scenarios) | TERMINAL | CHAT | MONITOR | VSCODE
- Key env: `DASHBOARD_URL`, `MCP_URL`, `N8N_URL`, `PROMETHEUS_URL`

### event-watcher  ← clawops namespace
- Port 8002 | image: `yanivomc/event-watcher:latest`
- Watches: `workshop` namespace only (`WATCH_NAMESPACES=workshop`)
- Cooldown: 60s between batches per deployment (`COOLDOWN_SECONDS=60`)
- Batches events for 10s then sends ONE payload to n8n S6 webhook
- Admin UI: `/events-admin/`
- SSE stream: `/events-admin/events/stream`

### target-app + chaos-loader sidecar  ← workshop namespace
- target-app port 8080 | image: `yanivomc/target-app:latest`
- chaos-loader port 8003 | image: `yanivomc/chaos-loader:latest`
- `SKIP_REGISTRATION=true` on target-app — sidecar handles registration
- Sidecar survives target-app restarts → dashboard instance always registered
- Chaos endpoints: `POST /chaos/error-loop` → `/tmp/.unhealthy` flag → all workers return 500
- Health: file-based flag `/tmp/.unhealthy` (shared across all uvicorn workers)

### linux-mcp-server  ← clawops namespace
- Port 8001 | image: `yanivomc/linux-mcp-server:latest`
- DNS: `linux-mcp-server.clawops.svc.cluster.local:8001`

### mcp-server  ← clawops namespace
- Port 8000 | SQLite incidents DB
- Tools: kubectl-read, kubectl-write, promql, incidents CRUD

---

## n8n Workflows

| ID | Name | Webhook | Purpose |
|----|------|---------|---------|
| S2 | AI Agent MCP | `/webhook/ai-agent` | General kubectl/promql AI agent |
| S2.5 | Linux Agent | `/webhook/linux-agent` | Linux MCP server agent |
| S4 | Telegram Human Loop | `/webhook/telegram-*` | TOTP approval flow |
| S5 | Alert Intelligence | `/webhook/prometheus-alert-s5` | Prometheus → AI → chat |
| S6 | K8s Event Intelligence | `/webhook/k8s-event-s6` | event-watcher → AI → chat |

**S6 flow:**  
event-watcher batch → Filter+Dedup → Check open incidents → Already open? → one-liner OR full AI investigation → Store incident → Chat with `/approve <totp> <key>`

---

## K8s Event Demo Pipeline

```
K8s Event Demo button (dashboard CHAOS SCENARIOS)
  → POST /api/chaos-loader/<id>/start?mode=error
  → chaos-loader sidecar: POST localhost:8080/chaos/error-loop every 15s
  → /tmp/.unhealthy created → all health checks return 500
  → K8s liveness fails x3 (45s) → kills target-app container
  → sidecar survives → immediately re-triggers on fresh container
  → event-watcher catches Unhealthy/Killing events (<1s)
  → 10s batch window → POST /webhook/k8s-event-s6
  → S6: check open incidents → AI investigates → dashboard chat
  → "SRE recommendation: run ./bootstrap-k8s.sh → Stop All"

Stop: click STOP ALL (chaos card) → DELETE /chaos/all → removes /tmp/.unhealthy
```

**chaos-loader /logs endpoint:** `GET /api/chaos-loader/<id>/logs`  
Returns JSON with recent activity — usable by n8n AI agent to explain WHY the app is failing.

---

## Bootstrap Menu

```
1) Full bootstrap    — install everything from scratch
2) Update configs    — re-apply configmaps + restart all pods (clawops + workshop)
3) Update ingress    — re-apply ingress rules
4) Import workflows  — push S2/S4/S5/S6 to n8n (requires API key)
5) Show TOTP QR      — instructor scans with Authy
6) Validate          — health checks all services
7) Delete ALL        — wipe cluster, fresh start
q) Quit
```

**First-time setup after fresh cluster:**
1. Run option `1` (full bootstrap)
2. Visit `http://<LB>/` → complete n8n owner setup (or it auto-completes via configmap)
3. Run option `4` to import workflows
4. Run option `5` to set up TOTP

---

## Images to Build/Push

```bash
# target-app (health fix — file-based flag)
cd target-app && docker build -t yanivomc/target-app:latest . && docker push yanivomc/target-app:latest

# chaos-loader sidecar (registration + logs)
cd chaos-loader && docker build -t yanivomc/chaos-loader:latest . && docker push yanivomc/chaos-loader:latest

# event-watcher (auto-reconnect)
cd event-watcher && docker build -t yanivomc/event-watcher:latest . && docker push yanivomc/event-watcher:latest

# dashboard
cd dashboard && docker build -t yanivomc/clawops-dashboard:latest . && docker push yanivomc/clawops-dashboard:latest

# linux-mcp-server (if not yet built)
cd linux-mcp-server && docker build -t yanivomc/linux-mcp-server:latest . && docker push yanivomc/linux-mcp-server:latest
```

---

## Known Issues / TODOs

- [ ] S6 auto-resolve incident when pod recovers (Started/Pulled events)
- [ ] Monitor tab: SSE event count resets on tab switch
- [ ] Stop All should also call `/api/chaos-loader/<id>/stop`
- [ ] Workshop lab docs (sessions 3-8)
- [ ] Day 2 slides
