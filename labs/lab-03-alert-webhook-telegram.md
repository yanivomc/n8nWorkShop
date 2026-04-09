# Lab 03 — Alert Webhook + AI Triage + Telegram

**Session 3 | Duration: ~60 min**

> In this lab you wire Prometheus Alertmanager directly to n8n. When a real Kubernetes failure fires, your AI Agent investigates the cluster and dispatches a structured triage report to Telegram — fully automated, no human needed until a write action is required.

---

## Architecture

```
Kubernetes Failure
    ↓  (pod crashes, OOM, etc.)
Prometheus detects → Alert fires
    ↓
Alertmanager → POST to n8n webhook
    ↓
n8n: Parse Alert
    ↓
AI Agent (Gemini) ←→ kubectl_read + promql (MCP Server)
    ↓
Format Telegram message
    ↓
Telegram Bot → on-call engineer
```

---

## Prerequisites

- Lab 01 complete (n8n running, Gemini credential saved)
- Lab 02 complete (S2 workflow works — AI Agent + MCP proven)
- Telegram bot token + your chat ID (from `telegram-bot-setup.md`)
- S3 workflow JSON imported (see Step 1)

---

## Step 1 — Import the S3 Workflow

```bash
export N8N_API_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhM2EyMzhlZS00MTM2LTRkMTQtOGE2Ny1hYWE1NGViYjVjNmMiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwianRpIjoiN2IzY2E2YTgtYmI3MC00MGE0LThjMDMtYzVlNjhjMmI0ZjViIiwiaWF0IjoxNzc1NTY1OTMzLCJleHAiOjE3NzgxMDEyMDB9.9ukVe0qiMA6l9X2ClDKTF7_M0vJAiEBwHyWmUklXlWU"

cd ~/n8nWorkShop && git pull

python3 -c "
import json
with open('n8n-workflows/s3-alert-webhook-telegram.json') as f: d=json.load(f)
d['settings']={'executionOrder':'v1','saveManualExecutions':True,'saveDataErrorExecution':'all','saveDataSuccessExecution':'all'}
with open('/tmp/s3.json','w') as f: json.dump(d,f)
" && curl -s -X POST http://localhost:5678/api/v1/workflows \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/s3.json | python3 -c "import sys,json; d=json.load(sys.stdin); print('Imported workflow ID:', d.get('id','ERR'))"
```

Open n8n → you should see **"S3 - Alert Webhook + AI Triage + Telegram"** in your workflow list.

---

## Step 2 — Add Your Telegram Credential

1. In n8n, go to **Settings → Credentials → Add Credential**
2. Search for **Telegram**
3. Enter your **Bot API Token** (from `@BotFather`)
4. Name it exactly: **`Telegram Bot`**
5. Save

> The workflow references this credential by name. If you name it differently, you'll need to update both Telegram nodes.

---

## Step 3 — Configure Your Chat ID

The workflow reads `TELEGRAM_CHAT_ID` from n8n variables.

**Option A — n8n Variables (recommended):**
1. Go to **Settings → Variables**
2. Add variable: key = `TELEGRAM_CHAT_ID`, value = your numeric chat ID
3. Save

**Option B — Edit nodes directly:**
1. Open each Telegram node in the workflow
2. Set the **Chat ID** field to your numeric chat ID directly

> Get your chat ID: Message your bot on Telegram, then visit:
> `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates`
> Your chat ID is in `result[0].message.chat.id`

---

## Step 4 — Activate the Workflow

1. Open the S3 workflow in n8n
2. Click **Inactive** toggle → switch to **Active**
3. The webhook is now live at:
   ```
   http://54.246.254.41:5678/webhook/prometheus-alert
   ```

> ⚠️ Webhook nodes only work when the workflow is **Active** (not just saved). If the workflow is inactive, Alertmanager POSTs will return 404.

---

## Step 5 — Test with force-alert.sh

Before waiting for a real Kubernetes failure, test the full pipeline using the scenario simulator:

```bash
cd ~/n8nWorkShop/k8s/scenarios

# Fire a CrashLoopBackOff alert (scenario 01)
./force-alert.sh 01

# Fire an OOMKilled alert (scenario 02)
./force-alert.sh 02

# Fire all 5 scenarios in sequence (with 3s delay between each)
./force-alert.sh all
```

**What to expect:**
1. Terminal shows `✅ Accepted (HTTP 200)`
2. In n8n → Executions, you see a new execution start
3. AI Agent calls `kubectl_read` + `promql` tool nodes
4. A structured triage message arrives in Telegram within ~15-20 seconds

**Example Telegram output:**
```
🔴 🚨 FIRING: PodCrashLooping

📍 Namespace: prod
🪲 Pod: payments-app-7d9f8b6c4-xkp2q
⚡ Severity: CRITICAL

📋 Summary:
Pod payments-app is crash looping

🤖 AI Triage:
SUMMARY: payments-app crashing every 5s due to non-zero exit code
SEVERITY: critical
ROOT_CAUSE: Container exits immediately — likely misconfigured command or missing dependency
CONFIDENCE: high
RECOMMENDED_ACTION: kubectl describe pod + check logs; consider rolling back deployment
REQUIRES_APPROVAL: no

🕐 Thu, 09 Apr 2026 10:34:22 GMT
```

---

## Step 6 — Trigger a Real Alert

Now trigger an actual failure to prove the Alertmanager → n8n path is live.

### Inject CrashLoopBackOff (Scenario 01)

```bash
# Deploy the crashing app
cd ~/n8nWorkShop/k8s/scenarios/01-crashloop
./inject.sh prod

# Watch it crash
kubectl get pods -n prod -w

# Wait 1-2 minutes for Prometheus to detect → Alertmanager to fire → n8n to receive
```

**The alert chain:**
1. Pod restarts repeatedly → `rate(kube_pod_container_status_restarts_total[5m]) * 60 > 0`
2. Alert fires in Prometheus after `for: 1m`
3. Alertmanager batches + POSTs to your n8n webhook
4. n8n executes → Telegram message delivered

### Watch the webhook receive the payload

In n8n → **Executions** tab — you'll see the execution with the real Alertmanager payload. Click into it to inspect each node's output.

### Cleanup

```bash
cd ~/n8nWorkShop/k8s/scenarios/01-crashloop
./cleanup.sh prod
```

---

## Step 7 — Explore Other Scenarios

| Script | Alert | Wait time |
|--------|-------|-----------|
| `./inject.sh prod` in `01-crashloop/` | PodCrashLooping | ~1 min |
| `./inject.sh prod` in `02-oom-kill/` | PodOOMKilled | immediate |
| `./inject.sh prod` in `03-pending-pods/` | PodNotReady | ~2 min |
| `./inject.sh prod` in `04-failed-deployment/` | DeploymentReplicasMismatch | ~3 min |
| `./inject.sh prod` in `05-flapping-alert/` | NodeHighCPU | ~2 min |

> **Tip for demos:** Use `force-alert.sh` for instant feedback, `inject.sh` for proof of the real Alertmanager path.

---

## Troubleshooting

### n8n returns 404 to force-alert.sh
→ Workflow is not Active. Toggle it Active in n8n.

### Telegram message not delivered
→ Check the Telegram credential is saved with name "Telegram Bot"
→ Verify `TELEGRAM_CHAT_ID` is set in Settings → Variables
→ Test your bot manually: send it `/start` in Telegram

### AI Agent not calling both tools
→ Check the system prompt is attached — open the AI Agent node and verify Gemini is connected
→ Try rephrasing the trigger input to explicitly mention kubectl and PromQL

### Real Alertmanager not reaching n8n
→ Verify Alertmanager config: `kubectl get secret alertmanager-monitoring-kube-prometheus-alertmanager -n monitoring -o yaml`
→ Confirm EC2 IP in the webhook URL matches current IP
→ Run `setup.sh` option 3 to reconfigure with current EC2 IP, then option 6 to re-apply Helm chart

### Webhook URL after EC2 restart
If EC2 IP changes, Alertmanager needs to be reconfigured:
```bash
cd ~/n8nWorkShop/student-env
# Edit .env: update EC2_PUBLIC_IP
./setup.sh  # Option 3 (Configure API keys) → Option 6 (Install Prometheus + Grafana)
```

---

## Key Concepts Covered

- **Webhook triggers** — how n8n receives external POST requests and makes them available as workflow input
- **Alertmanager payload structure** — `alerts[]`, `commonLabels`, `commonAnnotations`, `status` fields
- **AI Agent with real context** — feeding alert metadata into the prompt so the agent investigates the right namespace/pod
- **Error path** — separate Telegram node on the error output ensures on-call is notified even when AI fails
- **force-alert.sh** — testing webhooks without waiting for real failures (critical for demos and CI)

---

## What's Next

**Lab 04** adds the human-in-the-loop: when the AI recommends a write action, Telegram sends YES/NO/INFO buttons. Your approval (or rejection) gates the `kubectl-write` tool on the MCP server.

---

## 📊 Slide Note — Good vs Bad Design (S3 Teaching Point)

> **Add this as a "Good vs Bad" comparison slide when building the deck.**

**❌ Bad — Hardcoded field parser (Set node):**
```
$json.alerts[0].labels.pod
$json.alerts[0].labels.namespace
$json.commonLabels.severity
```
- Breaks when alert schema changes
- Breaks when a non-pod resource fires (Deployment, Service, Node, HPA...)
- Requires a developer to update the workflow for every new alert type
- Brittle, zero adaptability

**✅ Good — LLM as semantic parser:**
- System prompt anchors context: *"Alertmanager, Kubernetes cluster"*
- LLM reads the raw payload and understands *meaning*, not field names
- Output is always a consistent investigation brief regardless of input shape
- Works today for pods, tomorrow for services, next week for HPAs — zero changes
- Bonus: LLM can even suggest targeted investigation commands based on what it understood

**The principle:** Use hardcoded parsers for stable, well-defined schemas. Use LLMs when the schema varies, evolves, or carries semantic meaning that needs interpretation.

---

## 📊 Slide Note — LLM Parser: Why JSON-only matters

> **Add this as a teaching point in the slides when covering the LLM Parser node.**

**The problem with LLM output in pipelines:**
LLMs default to being helpful and formatted — they add markdown, headers, code fences. In a conversational context that's great. Inside an automation pipeline it breaks everything downstream.

**The pattern to teach:**
- System prompt must say *"ONLY return raw JSON — first character must be `{`, last must be `}`"*
- Always add a strip step before `JSON.parse()` to remove any ```` ```json ```` fences Gemini might still add
- Always add a fallback in case JSON.parse fails — the pipeline must never crash on bad LLM output

**Good vs Bad:**
- ❌ Bad: `JSON.parse($json.text)` — crashes if LLM adds a single markdown character
- ✅ Good: strip fences → parse → catch → sensible fallback

