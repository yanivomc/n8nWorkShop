# Setup Guide — ClawOps Workshop (Kubernetes)

Everything runs on a Kubernetes cluster (kops, AWS, 2 nodes) behind **one** nginx
ingress LoadBalancer. The single `bootstrap-k8s.sh` script installs, configures,
validates, and tears down the whole stack. There is no Docker Compose, no ngrok,
and no Telegram — all human interaction happens in the ClawOps **dashboard chat**.

> Looking for the old EC2 + Docker Compose + ngrok + Telegram guide? It's archived
> under `_archive/student-env/` and `docs/_archive/`.

---

## Prerequisites

- A running Kubernetes cluster (kops on AWS, ~2 nodes) and a working `kubectl`
  context pointing at it
- `helm` (for the monitoring + ingress stacks)
- `docker` + push access to the `yanivomc/*` images (only if you rebuild images)
- A Gemini API key — <https://aistudio.google.com/app/apikey>

---

## Step 1 — Clone and bootstrap

```bash
git clone https://github.com/yanivomc/n8nWorkShop.git
cd n8nWorkShop

./bootstrap-k8s.sh run     # non-interactive: install/upgrade everything
# or
./bootstrap-k8s.sh         # interactive menu
```

### Menu options

| # | Action |
|---|--------|
| 1 | Full bootstrap — install/upgrade everything |
| 2 | Update configs — re-apply configmaps + restart pods |
| 3 | Update ingress — re-apply ingress rules |
| 4 | Import workflows — push S2/S2.5/S4/S5/S6/S8 to n8n (prompts for n8n API key) |
| 5 | Show TOTP / QR — display the approval-gate secret |
| 6 | Reset incidents — clear all MCP incidents |
| 7 | Validate — run health checks |
| 8 | Delete ALL — wipe everything for a fresh start |

The full bootstrap installs ingress-nginx, the kube-prometheus-stack
(Prometheus + Grafana + Alertmanager, all ClusterIP), and all `clawops` /
`workshop` workloads, then wires Alertmanager to the n8n S5 webhook.

---

## Step 2 — Find the ingress URL

Everything is served from one LoadBalancer:

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

| Service | Path |
|---------|------|
| n8n | `http://<LB>/` |
| ClawOps dashboard | `http://<LB>/dashboard/` |
| MCP docs | `http://<LB>/mcp/docs` |
| Prometheus | `http://<LB>/prometheus` |
| Grafana | `http://<LB>/grafana` |
| Alertmanager | `http://<LB>/alertmanager/` |
| Event-watcher admin | `http://<LB>/events-admin/` |

> n8n is at the **root `/`**, not `/n8n/`.

---

## Step 3 — Configure n8n in the browser

Open `http://<LB>/`.

1. **Owner account** — first run shows a setup wizard; create any owner account
   (basic auth `admin` / `changeme123` from `n8n-config` fronts it).
2. **Gemini credential** — Settings → Credentials → Add → search `Google Gemini`
   → **Google Gemini(PaLM) Api** → paste your key → save as
   **`Google Gemini(PaLM) Api account`** (workflows reference this exact name).
3. **n8n API key** — Settings → API → Create API Key (used by bootstrap option 4
   to import workflows; it's saved into the `n8n-config` ConfigMap for reuse).

> ⚠️ n8n stores credentials in its **PVC-backed database** (`n8n-data`), not in any
> config file. If that PVC is wiped you must re-add the Gemini credential. This is
> the first thing to check on "Node does not have any credentials set".

> n8n is pinned to **`n8nio/n8n:1.123.62`**. Do **not** use `:latest` — the 2.x line
> ships a broken editor (blank UI). See the root `CLAUDE.md` gotchas.

---

## Step 4 — Import workflows

```bash
./bootstrap-k8s.sh        # option 4
```

It strips `id`/`versionId` and `POST`s each workflow to the n8n API
(`s2-ai-agent-mcp`, `s2.5-linux-agent`, `s4-dashboard-human-loop`,
`s5-alert-intelligence`, `s6-k8s-event-intelligence`, `s8-k8s-event-jwt`).
After import, open each workflow, set the Gemini credential on the AI Agent
nodes, and toggle **Active**.

> **Use S5 _or_ S6 — not both** (they detect the same events from different
> sources and would create duplicate incidents). **S8 = S6 + JWT auth** — use it
> instead of S6 to teach the security gate.

---

## Step 5 — TOTP approval gate

The approval gate validates a TOTP code inside the MCP server (`pyotp`).

```bash
./bootstrap-k8s.sh        # option 5 — shows the secret + QR, generating it if missing
```

Register the secret in Authy / Google Authenticator (Account: `ClawOps Workshop`,
Time-based). If you rotate the secret manually:

```bash
# generate inside the MCP pod (the cluster master has no pip3)
kubectl exec -n clawops deployment/mcp-server -- python3 -c "import pyotp; print(pyotp.random_base32())"
# then restart so it picks up the new secret
kubectl rollout restart deployment/mcp-server -n clawops
```

---

## Step 6 — Run the loop

1. Open the dashboard: `http://<LB>/dashboard/`.
2. **DASHBOARD** tab → trigger a chaos scenario on `target-app`.
3. Prometheus alert fires → Alertmanager → n8n **S5** → AI enriches → posts to the
   **CHAT** tab with an incident key.
4. Reply in chat: `/approve <totp> <key>` → S4 validates the TOTP → MCP runs the
   `kubectl-write` → result posted back, incident marked resolved.

The **MONITOR** tab shows the live K8s event stream (via the event-watcher SSE)
and pod topology.

---

## Validation

```bash
./bootstrap-k8s.sh        # option 7
```

Checks the `clawops` / `workshop` pods, n8n & MCP health, the chaos-loader,
event-watcher, linux-mcp, ingress LB reachability, and the dashboard.

---

## Force a test alert (no real chaos)

```bash
N8N_IP=$(kubectl get svc n8n -n clawops -o jsonpath='{.spec.clusterIP}')
curl -s -X POST http://${N8N_IP}:5678/webhook/prometheus-alert-s5 \
  -H "Content-Type: application/json" \
  -d '{"alerts":[{"labels":{"alertname":"TargetAppCPUStress","severity":"warning","workshop":"true","namespace":"workshop","pod":"target-app-xxx"},"status":"firing"}]}'
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| n8n shows a blank page | Image must be `1.123.62`, not `:latest` (2.x writes a 0-byte editor). |
| "Node does not have any credentials set" | Re-add the Gemini credential in the n8n UI (lives in the `n8n-data` PVC). |
| MCP promql → 503 / "Prometheus unavailable" | `PROMETHEUS_URL` must be the internal DNS **with** the `/prometheus` routePrefix (option 2 re-applies it). |
| `config.js` shows `INJECT_*` | Run bootstrap option 2 to re-apply configmaps. |
| TOTP "invalid token" | Regenerate inside the MCP pod (has `pyotp`), then restart `mcp-server`. |
| Alertmanager not reaching n8n | It must point to `http://n8n.clawops.svc.cluster.local:5678/webhook/prometheus-alert-s5`. |
| Prometheus redirect loop | Don't add an nginx rewrite for Prometheus — Prefix path only. |

---

## Workflow states (teaching → production)

| Workflow | Trigger | Output | Notes |
|----------|---------|--------|-------|
| S2 | n8n Chat UI | n8n chat | K8s + PromQL agent |
| S2.5 | n8n Chat UI | n8n chat | adds the Linux MCP tool |
| S4 | `/webhook/dashboard-chat` | dashboard chat | human loop + TOTP approval |
| S5 | Alertmanager webhook | dashboard chat | alert enrichment + confidence |
| S6 | event-watcher webhook | dashboard chat | K8s event intelligence (use S5 **or** S6) |
| S8 | event-watcher webhook + JWT | dashboard chat | S6 with a JWT auth gate |

**The full loop:** dashboard chaos → Prometheus alert → Alertmanager → S5 → AI
enriches + scores confidence → dashboard chat with incident key → engineer replies
`/approve <totp> <key>` → S4 → MCP `kubectl-write` → confirmation back to chat.
