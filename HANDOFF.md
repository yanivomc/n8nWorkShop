# ClawOps n8n Workshop — Handoff Document
**Last updated:** 2026-06-30  
**Repo:** https://github.com/yanivomc/n8nWorkShop  

---

## Recent fixes (2026-06 — all on `main`, validated on a fresh cluster)

Fresh-cluster bootstrap now comes up **complete with zero manual deploys** (only
student steps left: attach the Gemini credential + activate the imported workflows).

- **n8n blank UI** — EBS CSI PVC truncated n8n's 1MB frontend cache at 64KB on
  first boot. `.cache` now mounts on a node-local **emptyDir** (regenerable),
  off the PVC. (`k8s/clawops/n8n/deployment.yaml`)
- **event-watcher + linux-mcp never deployed** — bootstrap used an **undefined
  `$K8S_DIR`** for those applies (silent failure). Fixed → `$CLAWOPS_DIR`.
- **Grafana subpath + TargetDown** — `GF_SERVER_ROOT_URL` shipped a literal
  `INJECT_INGRESS_LB`; bootstrap now substitutes it. Fixed UI **and** the scrape.
- **Memory-leak chaos** — target-app raised 512Mi → **768Mi** so the leak
  sustains and fires `TargetAppMemoryLeak`/`MemoryCritical` instead of OOMing.
- **kops alert noise** — `prometheus-values.yaml` disables the noisy default rule
  groups; `workshop.pods` rules scoped to `namespace="workshop"`.
- **S5 honest enrichment** — no more fake `CPU Stress=0`; the AI runs the signal
  plan live; the `Worth Escalating?` gate is real (firing→AI, resolved→log).
- **Dashboard** — MONITOR tab gained an **ACTIVE PROBLEMS** panel (firing
  `workshop=true` alerts, so CPU/error/latency chaos shows); header decluttered;
  **◆ ARCHITECTURE** link opens the ClawOps Live page (`present.html`).
- **All chaos scenarios verified** end-to-end through S5 (CPU/memory/error/latency).
- **Slides rebuilt & validated:** Section 1 (+ Learning-Flow map), 2, 3 (Alert
  Intelligence), 4 (Human Approval), Monitoring (new), Security, S6. Decks use
  role-names; the `Sx` numbers are kept everywhere in code (too widespread to
  rename — see the Learning-Flow slide which explains "Sx = build order, not
  teaching order").

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
| S4 | Human Loop | `/webhook/dashboard-chat` | TOTP approval (dashboard chat, not Telegram) |
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
- **MONITOR** — **ACTIVE PROBLEMS** (firing `workshop=true` Prometheus alerts, so
  CPU/error/latency chaos surfaces) + pod topology + real-time K8s event stream +
  lifecycle timeline

Monitor connects to `/events-admin/events/stream` SSE (event-watcher) for events,
`/api/pods/{ns}` for topology, and `/prometheus/api/v1/alerts` for ACTIVE PROBLEMS.
Tab switching fixed — all panels properly hidden on switch.

---

## Images to Build

> Nodes are **x86_64** — always build for `linux/amd64` (arm64 from a Mac
> CrashLoops with `exec format error`). Use `docker buildx build --platform
> linux/amd64 ... --push` or `podman build --platform linux/amd64`.

```bash
docker buildx build --platform linux/amd64 -t yanivomc/target-app:latest --push ./target-app
docker buildx build --platform linux/amd64 -t yanivomc/chaos-loader:latest --push ./chaos-loader
docker buildx build --platform linux/amd64 -t yanivomc/event-watcher:latest --push ./event-watcher
docker buildx build --platform linux/amd64 -t yanivomc/clawops-dashboard:latest --push ./dashboard
docker buildx build --platform linux/amd64 -t yanivomc/mcp-server:latest --push ./mcp-server
docker buildx build --platform linux/amd64 -t yanivomc/linux-mcp-server:latest --push ./linux-mcp-server
```

---

## Known Issues / TODO

- [ ] S6 auto-resolve incident when pod recovers (Started/Pulled events)
- [ ] Monitor SSE event count resets on tab switch
- [ ] `linux-mcp-server` deploys into the **clawops** ns (manifest is under
      `k8s/clawops/`), but some refs mention `linux-mcp-server.workshop.svc` —
      reconcile the DNS the S2.5 workflow uses (cosmetic; service is healthy)
- [ ] Workshop lab docs (sessions 3-8)
- [x] ~~Day 2 slides~~ — Section 1–4 + Monitoring + Security + S6 decks done & validated
- [x] ~~Fresh-cluster bootstrap deploys everything~~ — validated (see Recent fixes)
