# Lab 04 — Telegram Human Loop

**Session 4 | Duration: ~60 min**

> S4 turns Telegram into a two-way K8s command interface. Part 1: ask the bot anything about your cluster and get an AI-investigated answer. Part 2: when the AI recommends a write action, it sends an approval prompt — you reply `/approve` or `/deny` to gate the actual `kubectl` execution.

---

## Architecture

```
Engineer types in Telegram
    ↓
Telegram Trigger → Route Message
    ├── query   → K8s Assistant (Gemini + kubectl_read + promql)
    │                ↓
    │           Check Write Needed
    │                ├── write needed → Send Approval Request → engineer replies
    │                │                        ↓ /approve or /deny
    │                │               Validate Approval → Execute Write (MCP gated)
    │                │                                       ↓
    │                │                              Send Execution Result
    │                └── read only  → Send Answer
    │
    └── /approve or /deny → Validate Approval → Execute Write or Send Denial
```

---

## Part 1 — Conversational K8s Assistant

### What you can ask

Type anything in Telegram — the bot investigates the cluster and replies:

```
check the status of nginx pods in prod namespace
what's the CPU usage on the nodes?
are there any failing deployments?
show me recent events in the monitoring namespace
```

The AI Agent runs `kubectl_read` and/or `promql` based on your question, then replies concisely with emojis.

### Import the workflow

```bash
export N8N_API_KEY="<your n8n API key>"
cd ~/n8nWorkShop && git pull

python3 -c "
import json
with open('n8n-workflows/s4-telegram-human-loop.json') as f: d=json.load(f)
d['settings']={'executionOrder':'v1','saveManualExecutions':True,'saveDataErrorExecution':'all','saveDataSuccessExecution':'all'}
with open('/tmp/s4.json','w') as f: json.dump(d,f)
" && curl -s -X POST http://localhost:5678/api/v1/workflows \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/s4.json | python3 -c "import sys,json; d=json.load(sys.stdin); print('Imported:', d.get('id','ERR'))"
```

### Configure Telegram credential

The workflow uses **"Telegram Bot"** credential — same one from lab-03. If it's already saved, just open each Telegram node and select it.

### Activate the workflow

Toggle the workflow **Active** in n8n. The Telegram Trigger uses a webhook — n8n registers it with Telegram automatically when activated.

### Test Part 1

Open Telegram, message your bot:
```
check the status of nginx pods in prod namespace
```

Expected reply within ~10 seconds:
```
⚠️ Namespace 'prod' not found on the cluster.
Available namespaces: default, kube-system, monitoring
...
```

---

## Part 2 — Write Approval Gate

### How it works

When the AI recommends a write action, it adds to its response:
```
WRITE_NEEDED: rollout restart deployment/payments -n prod
```

The `Check Write Needed` node detects this and sends:
```
⚠️ Write action recommended:
kubectl rollout restart deployment/payments -n prod

Approve?
✅ /approve <token> rollout restart deployment/payments -n prod
❌ /deny
```

You reply with the exact `/approve` or `/deny` command. The token is validated against `WRITE_APPROVAL_TOKEN` in `.env`. If valid, `kubectl-write` on the MCP server executes the command and reports back.

### Test Part 2

First inject a crashloop scenario:
```bash
cd ~/n8nWorkShop/k8s/scenarios/01-crashloop
./inject.sh prod
```

Then ask the bot:
```
the payments app in prod is crashing — what should we do?
```

The AI investigates, confirms the crashloop, and recommends a restart. You'll receive the approval prompt. Reply `/approve <token> rollout restart deployment/payments-app -n prod` to execute.

---

## Key Concepts

**Two conversation flows in one workflow:**
- `Route Message` splits traffic: `/approve`/`/deny` → approval path, everything else → assistant path
- This keeps the workflow clean — one trigger, two distinct behaviors

**Write gate architecture:**
- AI Agent never calls `kubectl-write` directly — it can only signal `WRITE_NEEDED`
- Actual execution requires: valid token + human `/approve` in Telegram
- Denial or invalid token → nothing executes, safe by default

**`WRITE_APPROVAL_TOKEN` security:**
- Token is in `.env`, never in the workflow
- `mcp-server` validates it server-side — n8n can't bypass it

---

## 📊 Slide Note — Conversational vs Reactive

> **Two patterns taught in S3 + S4:**

- **S3 — Reactive:** Alertmanager fires → n8n processes → Telegram notified. No human needed to trigger it.
- **S4 Part 1 — Conversational:** Human asks → AI investigates → Human gets answer. Pull model.
- **S4 Part 2 — Approval Gate:** AI recommends → Human gates → System executes. Human in the loop for writes only.

All three use the same Telegram bot and MCP tools — just different trigger patterns.
