# Archived docs (Telegram era)

Superseded documentation from the pre-dashboard design (Telegram + ngrok + EC2
Docker Compose). Kept for reference — **not** the current workshop flow.

| File | Was | Now |
|------|-----|-----|
| `workflow-s3.md` | S3 Alert Webhook → AI triage → **Telegram** | Replaced by **S5** (dashboard chat) — see `n8n-workflows/s5-alert-intelligence.json` |
| `workflow-s4.md` | S4 **Telegram** human-loop + TOTP approval | Same approval flow, now in the dashboard chat — see `n8n-workflows/s4-dashboard-human-loop.json` |

Current design: all human interaction moved from Telegram to the ClawOps
dashboard chat (SSE). See `SLIDES_BRIEF.md` → "What Changed from Original Design".
