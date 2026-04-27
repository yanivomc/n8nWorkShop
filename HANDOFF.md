# ClawOps n8n Workshop — Handoff Document
**Last updated:** 2026-04-27  
**Repo:** https://github.com/yanivomc/n8nWorkShop  

---

## Architecture

```
clawops ns:  n8n | mcp-server | clawops-dashboard | event-watcher | linux-mcp-server
workshop ns: target-app (+ chaos-loader sidecar)
monitoring:  prometheus | grafana | alertmanager
ingress:     single LB → /, /dashboard/, /mcp/, /prometheus, /grafana, /alertmanager/, /events-admin/
```

---

## Services

### event-watcher (clawops ns, port 8002)
- Watches `workshop` namespace only
- Batches events 10s → sends ONE payload per deployment to n8n S6
- Cooldown: 60s between batches per deployment
- Admin UI: `/events-admin/`  |  SSE: `/events-admin/events/stream`

### target-app + chaos-loader sidecar (workshop ns)
- target-app port 8080 — `SKIP_REGISTRATION=true` (sidecar handles registration)
- chaos-loader port 8003 — always alive, survives target-app restarts
  - Registers pod with dashboard every 20s
  - `POST /start?mode=error` — starts pounding target-app with error-loop
  - `POST /stop` — stops loop (call this to stop chaos, even when target-app is restarting)
  - `GET /logs` — recent activity log for n8n AI
- Health fix: `/tmp/.unhealthy` file flag — shared across all uvicorn workers

### mcp-server (clawops ns, port 8000)
- Tools: `kubectl-read`, `kubectl-write` (includes `exec`), `promql`, incidents CRUD
- RBAC: `pods/log`, `pods/exec` allowed

---

## n8n Workflows

| | Workflow | Trigger | Use |
|--|---------|---------|-----|
| S2 | AI Agent MCP | `/webhook/ai-agent` | kubectl/promql agent |
| S2.5 | Linux Agent | `/webhook/linux-agent` | linux-mcp agent |
| S4 | Human Loop | `/webhook/telegram-*` | TOTP approval |
| S5 | Alert Intelligence | `/webhook/prometheus-alert-s5` | Prometheus alerts |
| **S6** | **K8s Event Intelligence** | `/webhook/k8s-event-s6` | Real-time K8s events |
| **S8** | **JWT Secured Events** | `/webhook/k8s-event-s8` | S6 + JWT auth gate |

**⚠️ Workshop instruction: use S5 OR S6 (not both). S8 = S6 with JWT — use instead of S6 to teach security.** — they detect the same events from different sources and will create duplicate alerts.

### S6 Flow
```
event-watcher batch → Filter+Dedup (empty=stop, deploy-keyed)
  → Check MCP incidents (match by deploy across S5+S6)
  → Already open? → "Still ongoing #key" (no AI re-run)
  → New → K8s Event Agent (pulls pod logs + sidecar logs)
         → Identifies: chaos test vs real outage
         → SRE_ACTION: kubectl exec <pod> -c chaos-loader -- curl -X DELETE http://localhost:8003/chaos/all
         → Store incident → Chat with /approve key
```


### S8 — JWT Secured Flow
```
event-watcher signs batch with HS256 JWT (30s exp, claims: ns/deploy/reason)
  → POST /webhook/k8s-event-s8  Authorization: Bearer <token>
  → Validate JWT (pure-JS HMAC-SHA256, no crypto module — works in n8n sandbox)
      → invalid/expired → execution fails, nothing processed (replay attack prevented)
      → valid → Send JWT Debug to chat (shows token claims)
  → Filter + Dedup → same S6 AI investigation flow

JWT_SECRET: "clawops-workshop-secret-change-in-prod" (in event-watcher configmap)
```
**Why manual validation (not n8n built-in JWT auth):**
- n8n built-in = black box, students learn nothing
- Our Code node validates exp claim (30s) → blocks replay attacks
- Validates custom claims (ns, deploy) → ensures token is from event-watcher
- n8n sandboxes crypto module → pure-JS SHA-256 implementation = extra lesson

---

## K8s Event Demo Pipeline

```
Click "K8s Event Demo" (chaos scenario card)
  → chaos-loader /start?mode=error → error-loop every 15s
  → /tmp/.unhealthy → all health checks = 500
  → K8s liveness fails ×3 (45s) → kills target-app
  → sidecar survives → re-triggers on fresh pod → repeat
  → event-watcher: Unhealthy/Killing events < 1s detection
  → 10s batch → S6 → AI investigates logs → chat

Stop: STOP ALL button → chaos-loader /stop FIRST → target-app /chaos/all
```

---

## Dashboard Tabs
- **DASHBOARD** — chaos scenarios + instance management
- **TERMINAL** — ttyd shell
- **CHAT** — incident chat (AI responses + approvals)
- **MONITOR** — real-time K8s event stream + pod topology + lifecycle timeline

Monitor connects to `/events-admin/events/stream` SSE. Tab switching fixed — all panels properly hidden on switch.

---

## Images to Build

```bash
docker build -t yanivomc/target-app:latest ./target-app && docker push yanivomc/target-app:latest
docker build -t yanivomc/chaos-loader:latest ./chaos-loader && docker push yanivomc/chaos-loader:latest
docker build -t yanivomc/event-watcher:latest ./event-watcher && docker push yanivomc/event-watcher:latest
docker build -t yanivomc/clawops-dashboard:latest ./dashboard && docker push yanivomc/clawops-dashboard:latest
docker build -t yanivomc/mcp-server:latest ./mcp-server && docker push yanivomc/mcp-server:latest
docker build -t yanivomc/linux-mcp-server:latest ./linux-mcp-server && docker push yanivomc/linux-mcp-server:latest
```

---

## Known Issues / TODO

- [ ] S6 auto-resolve incident when pod recovers (Started/Pulled events)
- [ ] Monitor SSE event count resets on tab switch  
- [ ] Workshop lab docs (sessions 3-8)
- [ ] **Day 2 slides** ← next
