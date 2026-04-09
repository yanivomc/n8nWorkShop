# Setup Guide — n8n DevOps Workshop

## Prerequisites

- AWS EC2 instance (Ubuntu 22.04, t3.medium or larger)
- Docker + docker compose installed
- Ports open: 5000 (ttyd), 5001 (VS Code), 5678 (n8n), 8000 (MCP server)
- A Gemini API key (https://aistudio.google.com/app/apikey)
- A Telegram bot token (from @BotFather) + your chat ID

---

## Step 1 — Clone the Repo

```bash
git clone https://github.com/yanivomc/n8nWorkShop.git
cd n8nWorkShop/student-env
cp .env.example .env
```

---

## Step 2 — Configure API Keys (setup.sh option 3)

```bash
./setup.sh   # choose option 3
```

This prompts for and saves to `.env`:
- **Gemini API key** — for AI Agent and LLM Parser
- **Telegram bot token** — for sending/receiving messages
- **Telegram chat ID** — your personal or group chat ID
- **ngrok static domain** — for HTTPS webhook (see ngrok section below)
- **TOTP secret** — auto-generated for 2FA approval gate (see MCP docs)
- **WRITE_APPROVAL_TOKEN** — fallback static token (auto-generated)
- **n8n admin password**

> ⚠️ **EC2 IP is auto-detected** from AWS metadata. If detection fails, enter manually.

---

## Step 3 — Install Prometheus + Grafana (option 4)

```bash
./setup.sh   # choose option 4
```

This runs `helm upgrade --install` for `kube-prometheus-stack` with:
- Prometheus on AWS LoadBalancer (port 9090)
- Grafana on AWS LoadBalancer (port 80) — admin / workshop123
- Alertmanager on AWS LoadBalancer (port 9093)
- Alertmanager routing: only `workshop="true"` alerts go to n8n webhook
- Auto-saves `PROMETHEUS_URL`, `GRAFANA_URL`, `ALERTMANAGER_URL` to `.env`

> ⚠️ **Must run option 4 before option 5.** The MCP server needs `PROMETHEUS_URL` at startup.

---

## Step 4 — Start Stack (option 5)

```bash
./setup.sh   # choose option 5
```

Starts two Docker containers:
- **n8n** on port 5678 — `WEBHOOK_URL` set to EC2 IP (or ngrok if configured)
- **mcp-server** on port 8000 — reads `PROMETHEUS_URL`, `TOTP_SECRET`, `WRITE_APPROVAL_TOKEN`

Stack won't start if `PROMETHEUS_URL` is missing — run option 4 first.

---

## Step 5 — Configure n8n in the Browser

Open `http://<EC2_IP>:5678`

### Create Owner Account
Fill in email, name, password on first run.

### Add Gemini Credential

> ⚠️ **Critical:** n8n stores credentials in its internal database (Docker volume), NOT in `.env`. If the EC2 is replaced or the volume is lost, you must re-add credentials manually. This is the first thing to check if you see "Node does not have any credentials set".

1. Settings → Credentials → Add Credential
2. Search: `Google Gemini`
3. Select: **Google Gemini(PaLM) Api**
4. Paste your Gemini API key
5. Save as: **`Google Gemini(PaLM) Api account`** (exact name — workflows reference it)

### Add Telegram Credential
1. Settings → Credentials → Add Credential
2. Search: `Telegram`
3. Paste your Bot Token
4. Save as: **`Telegram Bot`** (exact name)

### Add WRITE_APPROVAL_TOKEN to Variables
1. Settings → Variables → Add Variable
2. Key: `WRITE_APPROVAL_TOKEN`
3. Value: copy from `grep WRITE_APPROVAL_TOKEN ~/n8nWorkShop/student-env/.env`

---

## Step 6 — ngrok HTTPS Tunnel (for Telegram Trigger)

### Why ngrok?

Telegram **requires HTTPS** for bot webhooks. n8n runs on HTTP. ngrok creates a secure HTTPS tunnel from a public URL to your local n8n port.

### What is ngrok?

ngrok is a reverse proxy tunnel tool. It creates a publicly accessible HTTPS URL that forwards to a port on your EC2. Without it, Telegram cannot call your n8n webhook.

```
Telegram → HTTPS → ngrok → HTTP → n8n:5678
```

### Free Static Domain (Recommended)

ngrok free accounts get **one free static domain** — the URL never changes, even after restarts. Without it, the URL changes every restart and you must re-register the webhook.

1. Go to https://dashboard.ngrok.com/domains
2. Claim your free static domain (e.g. `yourname.ngrok-free.app`)
3. Add to setup.sh option 3 as `NGROK_DOMAIN`

### Start ngrok (option 10)

```bash
./setup.sh   # choose option 10
```

This:
1. Installs ngrok if missing
2. Authenticates with your `NGROK_AUTH_TOKEN`
3. Starts tunnel: `ngrok http 5678 --domain=$NGROK_DOMAIN`
4. Saves HTTPS URL to `.env` as `WEBHOOK_URL`
5. Restarts n8n so it picks up the new `WEBHOOK_URL`

> ⚠️ After restarting ngrok, **deactivate + reactivate** any Telegram Trigger workflows in n8n so the webhook re-registers with Telegram.

---

## Step 7 — Import Workflows

```bash
cd ~/n8nWorkShop
export N8N_API_KEY="<your key>"   # from n8n Settings → API Keys

# Import S3
python3 -c "
import json
with open('n8n-workflows/s3-alert-webhook-telegram.json') as f: d=json.load(f)
d['settings']={'executionOrder':'v1','saveManualExecutions':True,'saveDataErrorExecution':'all','saveDataSuccessExecution':'all'}
with open('/tmp/s3.json','w') as f: json.dump(d,f)
" && curl -s -X POST http://localhost:5678/api/v1/workflows \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/s3.json | python3 -c "import sys,json; d=json.load(sys.stdin); print('S3 imported:', d.get('id','ERR'))"

# Import S4
python3 -c "
import json
with open('n8n-workflows/s4-telegram-human-loop.json') as f: d=json.load(f)
d['settings']={'executionOrder':'v1','saveManualExecutions':True,'saveDataErrorExecution':'all','saveDataSuccessExecution':'all'}
with open('/tmp/s4.json','w') as f: json.dump(d,f)
" && curl -s -X POST http://localhost:5678/api/v1/workflows \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/s4.json | python3 -c "import sys,json; d=json.load(sys.stdin); print('S4 imported:', d.get('id','ERR'))"
```

After importing:
1. Open each workflow in n8n
2. Set credentials on any nodes showing a warning icon
3. Toggle **Active** to publish

---

## Step 8 — TOTP 2FA Setup (for S4 approval gate)

The S4 workflow uses TOTP (Time-based One-Time Passwords) for approving write operations — the same standard used by Google Authenticator and Authy.

### How it was generated

When you ran setup.sh option 3, it:
1. Built the MCP container (which has `pyotp` installed)
2. Generated a valid base32 secret inside the container
3. Saved it to `.env` as `TOTP_SECRET`
4. Showed you the secret key and a QR code URL

### Register in Authy or Google Authenticator

1. Open Authy or Google Authenticator
2. Add new account
3. Enter manually:
   - **Account name:** ClawOps Workshop
   - **Key:** your `TOTP_SECRET` value from `.env`
   - **Type:** Time-based

Or scan the QR code shown after setup.sh option 3.

### Using TOTP in S4

When the AI suggests a write action, Telegram sends:
```
⚠️ SRE Action suggested:
kubectl rollout restart deployment/payments-app -n prod

🔐 Enter your 6-digit Authenticator code:
✅ /approve <6-digit-code>
❌ /deny
```

Reply with `/approve 123456` — the code is validated by the MCP server against `TOTP_SECRET`.

---

## Validation

```bash
./setup.sh   # choose option 7
```

Runs 17 checks covering:
- Docker containers running
- n8n reachable
- MCP server reachable
- Prometheus LB reachable
- Grafana LB reachable
- kubectl cluster access
- All required env vars set

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Node does not have any credentials set" | Re-add Gemini/Telegram creds in n8n UI |
| MCP returns 503 Prometheus unreachable | Run option 4 to reinstall + update PROMETHEUS_URL, then option 5 to restart stack |
| Telegram webhook 404 | Workflow not Active, or ngrok not running — check option 10 |
| TOTP "invalid token" | Check TOTP_SECRET in container: `docker exec mcp-server env \| grep TOTP` |
| force-alert.sh HTTP 404 | EC2_PUBLIC_IP not in .env — run option 3 |
| Alertmanager still sending system alerts | Helm upgrade didn't apply — re-run option 4 |
