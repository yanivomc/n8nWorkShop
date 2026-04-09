# Lab 01 — n8n Initial Setup & Gemini Configuration

**Session:** Pre-workshop / Session 2 setup  
**Time:** ~20 minutes  
**Goal:** Configure n8n with Gemini credentials, enable Chat and Instance-level MCP

---

## Prerequisites

- n8n running at `http://<EC2_IP>:5678` (verify with `setup.sh` option 1)
- Gemini API key from instructor (also in your `.env` as `GEMINI_API_KEY`)
- Validation passing 17/17 (setup.sh option 7)

---

## Step 1 — Create Owner Account

The first time n8n starts it shows a setup wizard.

1. Open `http://<EC2_IP>:5678` in your browser
2. Fill in the form:
   - **Email** — use any email (e.g. `student@workshop.local`)
   - **First Name / Last Name** — your name
   - **Password** — minimum 8 chars, 1 number, 1 capital (e.g. `Workshop1`)
3. Click **Next** and skip the optional steps
4. You land on the n8n home screen — setup complete

> ⚠️ If you see a "Secure cookie" warning in the browser, it's expected — n8n is running over HTTP. The `N8N_SECURE_COOKIE=false` env var is already set in docker-compose.

---

## Step 2 — Add Gemini API Credential

1. In the left sidebar click **Overview** → **Credentials** tab (or navigate to `/home/credentials`)
2. Click **Add first credential** (or **Create credential** top right)
3. In the search box type `Google Gemini`
4. Select **Google Gemini(PaLM) Api**
5. Click **Continue**
6. In the **API Key** field paste your Gemini API key
   - Find it in your `CREDENTIALS.md` file, or run:
     ```bash
     grep GEMINI_API_KEY ~/n8nWorkShop/student-env/.env
     ```
7. Click **Save** — the credential appears as **Google Gemini(PaLM) Api account**

**Verify:** The credential card shows `Last updated just now` — no error banner.

> 🔑 **Important — credentials are NOT in the `.env` file.**  
> The `GEMINI_API_KEY` in `.env` is only used by `setup.sh` to generate `CREDENTIALS.md`.  
> n8n stores credentials in its **internal database** (the Docker volume).  
> **If the EC2 instance is replaced or the volume is lost, you must re-enter this credential manually** — every time, on every new instance. This is the first thing to check if the AI Agent reports "Node does not have any credentials set".

---

## Step 3 — Connect Gemini to n8n Chat

1. Click **Chat** in the left sidebar (Beta label)
2. Click **+ Start new chat**
3. Click **Base models** tab
4. Click **+ Add model**
5. Select **Google Gemini** from the provider list
6. Choose model: **gemini-1.5-pro** (or gemini-2.0-flash for faster responses)
7. Select the credential you just created
8. Click **Save**

**Test it:** Type `hello, are you working?` in the chat and verify you get a response.

---

## Step 4 — Enable Instance-level MCP

This exposes your n8n workflows as MCP tools that external AI clients (Claude Desktop, Cursor) can call.

1. Go to **Settings** → **Instance-level MCP** (bottom of sidebar)
2. Click **Enable MCP access**
3. The toggle turns green — **Enabled**
4. Click **Access token** tab
5. **Copy the token immediately** — you won't see it again
6. Note the **Server URL**: `http://<EC2_IP>:5678/mcp-server/http`

> ⚠️ Save your token somewhere safe now. If you lose it, you must regenerate it (this invalidates the old one).

**What this gives you:** Any MCP-compatible AI client can now discover and trigger your n8n workflows. We'll use this in the Session 2 bonus demo.

---

## Step 5 — Add Telegram Credential

You'll need this for Session 4. Get your bot token first (see `labs/telegram-bot-setup.md`).

1. Go to **Credentials** → **Create credential**
2. Search for `Telegram`
3. Select **Telegram API**
4. Paste your **Bot Token** (from @BotFather)
5. Click **Save**

---

## Step 6 — Add HTTP Request Credential for MCP Server

Your n8n workflows will call the MCP server. Pre-configure the base URL:

1. Go to **Credentials** → **Create credential**
2. Search for `Header Auth`
3. Select **Header Auth**
4. Name it: `MCP Server`
5. Header Name: `Content-Type`
6. Header Value: `application/json`
7. Click **Save**

> Note: MCP server runs at `http://mcp-server:8000` inside the Docker network (the service name resolves automatically).

---

## Verification Checklist

Run setup.sh option 7 — all should be green. Then verify manually:

| Check | Expected |
|-------|----------|
| n8n Chat → Base models | Gemini model listed and responds |
| Credentials page | Google Gemini(PaLM), Telegram API, Header Auth all saved |
| Settings → Instance MCP | Green "Enabled" toggle |
| `curl http://localhost:5678/mcp-server/http` | Returns MCP server info |

---

## What You Have Now

```
n8n (configured)
├── Gemini credential → AI Agent node can call Gemini
├── Telegram credential → Telegram trigger/send nodes
├── Chat interface → Base models → Gemini connected
└── Instance-level MCP → your workflows callable by AI clients
```

Next: **Lab 02 — Build the AI Agent + MCP workflow**
