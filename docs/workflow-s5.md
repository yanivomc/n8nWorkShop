# S5 — Alert Intelligence

## Purpose

S5 is the **production-grade upgrade of S3**. Where S3 reacts immediately to any alert, S5 first enriches the alert with live PromQL data, scores confidence based on correlated signals, and only escalates if multiple signals agree. Low-confidence alerts are logged and dropped — no Telegram noise.

---

## Key Difference from S3

| | S3 | S5 |
|--|----|----|
| Single signal | ✅ Escalates | ❌ Drops (low confidence) |
| Correlated signals | ✅ Escalates | ✅ Escalates with evidence |
| PromQL enrichment | ❌ | ✅ CPU + memory + restarts |
| Confidence score | ❌ | ✅ LOW / MEDIUM / HIGH |
| Duration check | ❌ | ✅ Spike vs sustained |
| Telegram message | Basic | Elegant with signal bars |

---

## Flow

```
Alertmanager → Dedup Filter
    ↓
Extract Brief + Signal Plan
  (maps alertname to relevant PromQL queries)
    ↓
PromQL Enrichment + Confidence Scoring
  (runs all signals, counts active, scores confidence)
    ↓
Worth Escalating? (IF node)
  ├── LOW confidence → Log only (silent drop)
  └── MEDIUM/HIGH → AI Agent (Gemini + kubectl_read + promql)
                        ↓
                   Format elegant Telegram message
                        ↓
                   Send (same chat as S4)
```

---

## Telegram Message Format

```
🚨 INCIDENT DETECTED
━━━━━━━━━━━━━━━━━━━━
📍 target-app-xyz / workshop
🏷 TargetAppCPUStress — 🔥 FIRING
⏱ Duration: 4m 12s

📊 Signal Correlation
  🔴 CPU Stress        ████████  1.0
  🔴 Memory Leak       ████░░░░  0.5
  🟢 Pod Restarts      ░░░░░░░░  0.0
Confidence: 🔴 HIGH (2/3 signals active)

🧠 AI Assessment
CPU stress scenario is active and sustained.
Memory is also increasing suggesting combined load test.
No crashes yet but trajectory is concerning.

✅ Recommended Action
kubectl rollout restart deployment/target-app -n workshop

💬 Reply /approve <totp> to execute via S4
━━━━━━━━━━━━━━━━━━━━
🕐 2026-04-12 09:14:32 UTC
```

---

## S4 Integration (Shared Context)

S5 sends to the **same Telegram chat** as S4. S4's `Chat Memory` window (last 10 messages) already contains S5's analysis. The on-call engineer can simply reply:

```
do it
```

S4's K8s Assistant understands "it" = the `SRE_ACTION` from S5's message. No re-explanation needed.

---

## Confidence Scoring

| Active Signals | Confidence | Action |
|---------------|-----------|--------|
| 0/3 | LOW | Silent drop |
| 1/3 | LOW | Silent drop |
| 2/3 | MEDIUM | Escalate |
| 3/3 | HIGH | Escalate |

Thresholds: `< 33%` = LOW, `33-66%` = MEDIUM, `>= 66%` = HIGH

---

## Signal Maps

Each alert type has a predefined set of PromQL signals to check:

**TargetAppCPUStress:** cpu_active + memory_active + restarts
**TargetAppMemoryLeak:** memory_active + memory_bytes + cpu_active
**TargetAppCrashLooping:** restarts + pod_ready + memory_active

---

## Webhook URL

```
http://<EC2_IP>:5678/webhook/prometheus-alert-s5
```

Update Alertmanager to route workshop alerts to S5 instead of S3, or run both in parallel (different receivers).
