# S5 — Alert Intelligence

## Purpose

S5 is the production-grade alert handler. Instead of reacting to every raw alert,
it first enriches the alert with live PromQL data (via the MCP `promql` tool),
scores confidence from correlated signals, and only escalates when multiple
signals agree. Low-confidence alerts are logged and dropped — no chat noise.

> S5 replaced the archived Telegram-based **S3** (`docs/_archive/workflow-s3.md`).
> All output now goes to the ClawOps **dashboard chat** (SSE), not Telegram.

---

## What makes S5 different

| | Naive alerting | S5 |
|--|----------------|----|
| Single signal | Escalates | Drops (low confidence) |
| Correlated signals | Escalates | Escalates with evidence |
| PromQL enrichment | ❌ | ✅ CPU + memory + restarts |
| Confidence score | ❌ | ✅ LOW / MEDIUM / HIGH |
| Duration check | ❌ | ✅ spike vs sustained |
| Output | Basic message | Structured incident card in dashboard chat |

---

## Flow

```
Alertmanager → Dedup Filter
    ↓
Extract Brief + Signal Plan
  (maps alertname to relevant PromQL queries)
    ↓
PromQL Enrichment + Confidence Scoring
  (runs all signals via MCP /tools/promql, counts active, scores confidence)
    ↓
Worth Escalating? (IF node)
  ├── LOW confidence → Log only (silent drop)
  └── MEDIUM/HIGH → AI Agent (Gemini + kubectl_read + promql via MCP)
                        ↓
                   Store incident in MCP  →  4-char key
                        ↓
                   POST /api/chat/send  →  dashboard chat (with key)
```

---

## What the engineer sees (dashboard CHAT tab)

```
🚨 INCIDENT DETECTED — TargetAppCPUStress
📍 target-app-xyz / workshop   ⏱ 4m 12s   🔥 FIRING

📊 Signal Correlation
  🔴 CPU Stress        ████████  1.0
  🔴 Memory Leak       ████░░░░  0.5
  🟢 Pod Restarts      ░░░░░░░░  0.0
Confidence: 🔴 HIGH (2/3 signals active)

🧠 AI Assessment
CPU stress scenario is active and sustained. Memory is also rising —
combined load test. No crashes yet but trajectory is concerning.

✅ Recommended Action
kubectl rollout restart deployment/target-app -n workshop

🔐 To approve: /approve <totp> k42a
```

---

## S4 integration (shared context)

S5 posts to the same dashboard chat as S4 and stores the incident in the MCP with
a 4-char key. The engineer approves with:

```
/approve <totp> <key>
```

S4 picks it up from the chat, fetches the incident command by key from the MCP,
validates the TOTP, and runs the `kubectl-write`. The key is the audit trail —
who approved what, when.

---

## Confidence scoring

| Active signals | Confidence | Action |
|---------------|-----------|--------|
| 0/3 | LOW | Silent drop |
| 1/3 | LOW | Silent drop |
| 2/3 | MEDIUM | Escalate |
| 3/3 | HIGH | Escalate |

Thresholds: `< 33%` = LOW, `33–66%` = MEDIUM, `>= 66%` = HIGH.

---

## Signal maps

Each alert type has a predefined set of PromQL signals to check:

- **TargetAppCPUStress:** cpu_active + memory_active + restarts
- **TargetAppMemoryLeak:** memory_active + memory_bytes + cpu_active
- **TargetAppCrashLooping:** restarts + pod_ready + memory_active

---

## Webhook

```
http://n8n.clawops.svc.cluster.local:5678/webhook/prometheus-alert-s5
```

Alertmanager routes only `workshop="true"` alerts to this receiver. Use **S5 or
S6**, not both — they would otherwise raise duplicate incidents for the same event.
