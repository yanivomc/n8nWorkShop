# Workshop Build Handoff — n8n DevOps Automation

## Project
8-hour hands-on workshop: AI-assisted incident command using n8n, Gemini, MCP, K8s, Prometheus/Grafana, Telegram.

**Repo:** https://github.com/yanivomc/n8nWorkShop.git

---

## Current EC2
| | |
|---|---|
| **IP** | `3.251.68.65` (dynamic) |
| **Terminal** | http://3.251.68.65:5000 |
| **n8n** | http://3.251.68.65:5678 |
| **MCP** | http://3.251.68.65:8000/docs |
| **Prometheus LB** | http://a26eacb3a567844368716083b871dd5f-672656453.eu-west-1.elb.amazonaws.com:9090 |
| **Grafana LB** | http://ae58db3f2c0dc44338e384a01796b8d5-1124178425.eu-west-1.elb.amazonaws.com (admin/workshop123) |
| **Dashboard LB** | http://a6f30eddf0aa5458e911a4e91fe89ac8-df1e1a0cfad3220c.elb.eu-west-1.amazonaws.com |

---

## Architecture
```
K8s (kops, 2 nodes) — namespace: workshop
  clawops-dashboard  (FastAPI LB:80) — UI + /api/register + /api/instances + chaos proxy
  clawops-dashboard-internal (ClusterIP) — target-app registers here
  target-app (FastAPI, NodePort:30080) — chaos scenarios + metrics
      ↓ registers on startup (background loop, auto-reconnects)
      ↓ Prometheus ServiceMonitor scrapes /metrics

Prometheus → alert rules (workshop=true) → Alertmanager → n8n webhook
n8n S3: Alert → LLM parse → AI Agent → Telegram
n8n S4: Telegram → K8s Assistant → TOTP approval → MCP write
MCP Server (Docker EC2:8000) — kubectl-read, promql, kubectl-write (TOTP)
```

---

## Session Status
| # | Session | Status |
|---|---------|--------|
| S2 | AI Agent + Gemini + MCP | ✅ READY |
| S3 | Alert Webhook + AI Triage + Telegram | ✅ READY |
| S4 | Telegram Human Loop + TOTP | ✅ READY |
| S5 | Alert Intelligence (enrichment) | ❌ TODO |
| S6–S8 | — | ❌ TODO |

---

## What's Done ✅
- **target-app** — chaos app (cpu/memory/crash/error-loop), Prometheus metrics, background registration loop
- **clawops-dashboard** — FastAPI (not nginx), serves UI + API, server-side chaos proxy, dead instance TTL
- **Auto-discovery** — target-app registers to dashboard ClusterIP on startup, re-registers every 30s
- **Prometheus alert rules** — TargetAppCPUStress, MemoryLeak, MemoryCritical, CrashLooping — baked into prometheus-values.yaml
- **ruleNamespaceSelector: {}** — Prometheus watches all namespaces — helm upgraded
- **Dashboard filters** — only workshop=true alerts shown
- **setup.sh** — 12 options, logical order, pre-flight checks, clean option
- **Docker Hub** — yanivomc/target-app:latest, yanivomc/clawops-dashboard:latest
- **Full docs** — docs/README.md, setup-guide.md, mcp-server.md, workflow-s3.md, workflow-s4.md

---

## What's Next (Sunday)
1. **Verify chaos proxy** — build/push latest dashboard, test CPU/memory/crash end-to-end from browser
2. **Test S3 end-to-end** — trigger CPU alert → Alertmanager → n8n → Telegram
3. **Build S5** — Alert Intelligence workflow
4. **Slides** — ClawOps workshop deck
5. **E2E test script** — test/validate-e2e.sh

---

## Key Commands
```bash
# Rebuild + push dashboard
cd ~/n8nWorkShop && git pull
cd dashboard && docker build -t yanivomc/clawops-dashboard:latest . && docker push yanivomc/clawops-dashboard:latest
kubectl rollout restart deployment/clawops-dashboard -n workshop

# Rebuild + push target-app
cd target-app && docker build -t yanivomc/target-app:latest . && docker push yanivomc/target-app:latest
kubectl rollout restart deployment/target-app -n workshop

# Re-apply dashboard ConfigMap after EC2 IP change
source student-env/.env
sed "s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL}|g;s|INJECT_GRAFANA_URL|${GRAFANA_URL}|g;s|INJECT_ALERTMANAGER_URL|${ALERTMANAGER_URL}|g;s|INJECT_N8N_URL|http://${EC2_PUBLIC_IP}:5678|g;" dashboard/k8s/dashboard.yaml | kubectl apply -f -
kubectl rollout restart deployment/clawops-dashboard -n workshop

# Check our alert rules loaded in Prometheus
curl -s "http://a26eacb3a567844368716083b871dd5f-672656453.eu-west-1.elb.amazonaws.com:9090/api/v1/rules" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); [print(r['name'],r['state']) for g in d['data']['groups'] for r in g['rules'] if 'TargetApp' in r['name']]"

# Trigger chaos via dashboard API
POD=$(kubectl get pod -n workshop -l app=target-app -o jsonpath='{.items[0].metadata.name}')
curl -s -X POST http://a6f30eddf0aa5458e911a4e91fe89ac8-df1e1a0cfad3220c.elb.eu-west-1.amazonaws.com/api/chaos/workshop%2F${POD}/action/cpu \
  -H "Content-Type: application/json" -d '{"cores":1,"duration_seconds":60}'
```

---

## Known Gotchas
- Dashboard instances are **in-memory** — pod restart = re-registration (target-app loop handles it in ~30s)
- Helm release name is `monitoring` not `kube-prometheus-stack`
- n8n credentials in Docker volume — re-add manually after EC2 replacement
- `imagePullPolicy: Always` on both K8s deployments
- setup.sh option 4 (start stack) requires PROMETHEUS_URL + KUBECONFIG — run 1→3 first
