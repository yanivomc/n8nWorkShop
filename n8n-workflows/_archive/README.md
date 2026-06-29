# Archived workflows

Kept for reference, **not imported** by `bootstrap-k8s.sh` and not used in the
live cluster. Do not delete — these document the pre-dashboard (Telegram) design.

| File | What it was | Replaced by |
|------|-------------|-------------|
| `s3-alert-webhook-telegram.json` | Prometheus alert → AI triage → **Telegram** notification | **S5** (`s5-alert-intelligence.json`) — same flow, output to the ClawOps dashboard chat |

Context: the workshop migrated all human interaction from Telegram to the
dashboard chat (SSE). See `SLIDES_BRIEF.md` → "What Changed from Original Design".
