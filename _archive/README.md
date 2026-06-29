# _archive — superseded by the Kubernetes design

These directories document the **original** workshop design (single EC2 +
Docker Compose + ngrok + Telegram). They are kept for reference and are **not**
used by the current stack. The whole workshop now runs on Kubernetes via
`bootstrap-k8s.sh`, with all human interaction in the ClawOps dashboard chat.

| Path | What it was |
|------|-------------|
| `student-env/` | Per-student Docker Compose env (`docker-compose.yml`, `setup.sh`, `.env.example`) — replaced by `bootstrap-k8s.sh` |
| `infrastructure/` | EC2 provisioning script (Docker, docker-compose, code-server) — replaced by the K8s cluster |

Related archives elsewhere in the repo:
- `n8n-workflows/_archive/` — Telegram-era S3 workflow
- `docs/_archive/` — Telegram-era S3/S4 docs
- `labs/_archive/` — Telegram-era labs + bot setup

See `SLIDES_BRIEF.md` → "What Changed from Original Design".
