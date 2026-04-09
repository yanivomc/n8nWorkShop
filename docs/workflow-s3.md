# S3 — Alert Webhook + AI Triage + Telegram

## Purpose

S3 is the **reactive alert pipeline**. When Prometheus detects a real Kubernetes failure, Alertmanager POSTs to n8n. The workflow parses the alert using an LLM (no hardcoded field names), runs a live cluster investigation, and delivers a structured triage report to Telegram — fully automated, no human needed until a write action is required.

---

## Flow

```
Kubernetes failure (pod crash, OOM, node pressure...)
    ↓
Prometheus → Alert fires
    ↓
Alertmanager → POST to n8n webhook (workshop=true alerts only)
    ↓
Dedup Filter — drops repeated firings within 10 min (test alerts bypass via run_id)
    ↓
Gemini JSON Parser — LLM reads raw payload, extracts structured brief
    ↓
Extract Brief — parses Gemini JSON response with safe fallback
    ↓
AI Agent (Gemini) — investigates cluster using kubectl_read + promql
    ↓
Format Telegram Message
    ↓
Telegram Alert → on-call engineer
```

---

## Nodes Explained

### Alertmanager Webhook
- **Type:** Webhook (POST)
- **Path:** `/prometheus-alert`
- **Mode:** `onReceived` — returns HTTP 200 immediately, workflow runs async
- Alertmanager is configured to only route alerts with `workshop="true"` label here

### Dedup Filter
- **Type:** Code node
- **Purpose:** Prevents the same alert from being processed multiple times
- Tracks `alertname:namespace:status` in workflow static data
- Drops duplicates within a **10-minute window**
- **Bypass:** If the payload contains `run_id` label (added by `force-alert.sh`), the alert always passes through — this allows test scripts to fire repeatedly without being blocked

### Gemini JSON Parser
- **Type:** HTTP Request → Gemini API directly
- **Why not chainLlm?** Gemini 2.5-flash ignores "JSON only" instructions when using the n8n LangChain node. Calling the API directly with `response_mime_type: application/json` and `response_schema` forces valid JSON at the API level — Gemini physically cannot return markdown.
- **System prompt:** Anchors context as "Alertmanager + Kubernetes cluster" — reads payload semantically, not by field names. Works for any K8s resource type: Pod, Deployment, Node, Service, HPA, PVC, etc.
- **Output schema:**
  ```json
  {
    "resource_type": "Pod",
    "resource_name": "payments-app-7d9f8b6c4-xkp2q",
    "namespace": "prod",
    "symptom": "Pod restarting 12 times/min",
    "severity": "critical",
    "status": "firing",
    "summary": "payments-app is crash looping",
    "kubectl_commands": ["describe pod payments-app-7d9f8b6c4-xkp2q -n prod"],
    "promql_queries": ["rate(kube_pod_container_status_restarts_total[5m])"]
  }
  ```

### Extract Brief
- **Type:** Code node
- Safely parses Gemini's JSON response
- If parsing fails → returns a sensible fallback brief so the pipeline never crashes

### AI Agent
- **Type:** LangChain Agent (Gemini 2.5-flash)
- Receives the structured investigation brief from `Extract Brief`
- Uses `kubectl_read` and `promql` tools to investigate
- System prompt is resource-type agnostic — adapts investigation strategy to whatever the brief says (pod → describe + logs, node → top nodes + memory PromQL, deployment → get deployment + events)
- Returns structured triage:
  ```
  SUMMARY: one-line status
  SEVERITY: critical / warning / healthy
  ROOT_CAUSE: assessment
  CONFIDENCE: high / medium / low
  RECOMMENDED_ACTION: specific steps
  REQUIRES_APPROVAL: yes/no
  ```

### Format Telegram Message
- Builds HTML-formatted Telegram message (not Markdown — avoids special char issues)
- Shows: resource, namespace, severity, summary, AI triage output, timestamp

### Error Path
- AI Agent error output → Format Error Message → Telegram Error
- On-call always gets notified even when AI fails

---

## Alertmanager Routing

Only alerts with label `workshop="true"` reach n8n. All system alerts (`KubeControllerManagerDown`, `Watchdog`, etc.) go to `null-receiver` and are silently swallowed.

```yaml
route:
  receiver: null-receiver          # default: swallow everything
  routes:
    - matchers:
        - workshop = "true"
      receiver: n8n-webhook
      repeat_interval: 12h         # same alert won't fire again for 12 hours
```

---

## Testing Without Waiting for Prometheus

Use `force-alert.sh` to send realistic Alertmanager payloads instantly:

```bash
cd ~/n8nWorkShop/k8s/scenarios

./force-alert.sh 01          # PodCrashLooping (critical)
./force-alert.sh 02          # PodOOMKilled (critical)
./force-alert.sh 03          # PodNotReady (warning)
./force-alert.sh 04          # DeploymentReplicasMismatch (warning)
./force-alert.sh 05          # NodeHighCPU (warning)
./force-alert.sh all         # All 5 with 3s delay between each
./force-alert.sh 01 resolved # Send resolved signal
```

Each payload includes a unique `run_id` label — this bypasses the Dedup Filter so test scripts can be run repeatedly.

---

## Triggering Real Alerts

```bash
# Inject a real CrashLoopBackOff
cd ~/n8nWorkShop/k8s/scenarios/01-crashloop
./inject.sh prod

# Watch it crash
kubectl get pods -n prod -w

# Wait ~1 min for Prometheus to detect → Alertmanager to fire → n8n to receive
# Cleanup when done
./cleanup.sh prod
```

---

## Design Decisions (Slide-worthy)

**LLM as semantic parser vs hardcoded field extractor:**

❌ **Bad (hardcoded Set node):**
```
$json.alerts[0].labels.pod
$json.alerts[0].labels.namespace
```
Breaks on schema changes, only works for pods.

✅ **Good (LLM parser):**
- Reads payload semantically — understands meaning, not field names
- Works for Pod, Deployment, Node, Service, HPA, PVC, anything
- Suggests targeted kubectl commands and PromQL queries based on what it understands
- Zero workflow changes needed when alert structure evolves

**Filter at the router, not the consumer:**

❌ Route all alerts to n8n, filter in the workflow
✅ Alertmanager routes only `workshop="true"` to n8n — system noise never enters the pipeline
