# Lab 01 — n8n Initial Setup & Gemini Configuration

**Session:** Pre-workshop / Session 2 setup
**Time:** ~15 minutes
**Goal:** Create the n8n owner account, add the Gemini credential, and create an
n8n API key so workflows can be imported.

---

## Prerequisites

- The stack is bootstrapped (`./bootstrap-k8s.sh run`) and pods are healthy
  (`./bootstrap-k8s.sh` → option 7)
- The ingress LB hostname:
  ```bash
  kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  ```
- A Gemini API key from the instructor — <https://aistudio.google.com/app/apikey>

> n8n is served at the LB **root `/`**, not `/n8n/`.

---

## Step 1 — Create Owner Account

The first time n8n starts it shows a setup wizard.

1. Open `http://<LB>/` in your browser.
   - A basic-auth prompt appears first — `admin` / `changeme123` (from `n8n-config`).
2. Fill in the owner form:
   - **Email** — any email (e.g. `student@workshop.local`)
   - **First / Last Name** — your name
   - **Password** — min 8 chars, 1 number, 1 capital (e.g. `Workshop1`)
3. Click **Next** and skip the optional steps. You land on the n8n home screen.

> ⚠️ A "secure cookie" browser warning is expected — n8n runs over HTTP and
> `N8N_SECURE_COOKIE=false` is already set in the `n8n-config` ConfigMap.

---

## Step 2 — Add the Gemini API Credential

1. Sidebar → **Overview** → **Credentials** → **Add credential**.
2. Search `Google Gemini` → select **Google Gemini(PaLM) Api** → **Continue**.
3. Paste your Gemini API key in the **API Key** field.
4. **Save.** It must appear as **`Google Gemini(PaLM) Api account`** — the
   workflows reference this exact credential name.

**Verify:** the credential card shows `Last updated just now` with no error banner.

> 🔑 **Credentials live in n8n's database (the `n8n-data` PVC), not in any config
> file.** If that PVC is wiped you must re-add this credential. This is the first
> thing to check if the AI Agent reports "Node does not have any credentials set".

---

## Step 3 — Connect Gemini to n8n Chat (S2/S2.5)

1. Click **Chat** in the left sidebar → **+ Start new chat**.
2. **Base models** tab → **+ Add model**.
3. Select **Google Gemini**, choose a model (e.g. `gemini-2.5-flash`), and pick the
   credential from Step 2.
4. **Save**, then type `hello, are you working?` and confirm you get a response.

---

## Step 4 — Create an n8n API Key

The bootstrap importer (option 4) pushes workflows over the n8n REST API.

1. **Settings** → **API** → **Create API Key**.
2. **Copy the key immediately** — you won't see it again.
3. Run the importer and paste the key when prompted:
   ```bash
   ./bootstrap-k8s.sh    # option 4
   ```
   It saves the key into the `n8n-config` ConfigMap for future runs and imports
   S2, S2.5, S4, S5, S6, S8.

> ⚠️ If you lose the key, regenerate it (this invalidates the old one).

---

## Step 5 — (Reference) MCP server endpoint

Workflows call the MCP server over in-cluster DNS — no credential needed:

```
http://mcp-server.clawops.svc.cluster.local:8000
```

The langchain HTTP tool nodes already point here. Quick check from your machine:

```bash
kubectl exec -n clawops deployment/mcp-server -- curl -s http://localhost:8000/health
# {"status": "ok", "tools": ["kubectl-read", "promql", "kubectl-write"]}
```

---

## Verification Checklist

Run `./bootstrap-k8s.sh` → option 7 (all green), then verify in the UI:

| Check | Expected |
|-------|----------|
| n8n Chat → Base models | Gemini model listed and responds |
| Credentials page | `Google Gemini(PaLM) Api account` saved, no error |
| Settings → API | An API key exists (saved to `n8n-config`) |
| Imported workflows | S2 / S2.5 / S4 / S5 / S6 / S8 present after option 4 |

---

## What You Have Now

```
n8n (configured)
├── Gemini credential → AI Agent nodes can call Gemini
├── Chat interface → Base models → Gemini connected (S2 / S2.5)
├── n8n API key → bootstrap option 4 can import workflows
└── Workflows imported → set the Gemini credential on each AI Agent, toggle Active
```

> Human-in-the-loop (S4) and alerts (S5) happen in the **ClawOps dashboard chat**
> (`http://<LB>/dashboard/` → CHAT tab) — no Telegram bot needed.

Next: **Lab — Build the AI Agent + MCP workflow** (`lab-linux-mcp-server.md` extends it).
