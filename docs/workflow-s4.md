# S4 — Telegram Human Loop

## Purpose

S4 turns Telegram into a two-way K8s command interface with a TOTP-gated write approval flow:

- **Part 1 — Conversational assistant:** Ask anything about the cluster in plain English. The AI investigates using kubectl + PromQL and replies concisely with context memory.
- **Part 2 — Approval gate:** When the AI recommends a remediation action, it prompts for a 6-digit TOTP code. Only after validation does the MCP server execute the write command.

---

## Flow

```
Engineer messages Telegram bot
    ↓
Telegram Trigger (HTTPS via ngrok)
    ↓
Route Message — splits traffic:
    ├── /approve or /deny → Validate Approval path
    └── anything else    → K8s Assistant path

K8s Assistant path:
    K8s Assistant (Gemini + kubectl_read + promql + Chat Memory)
        ↓
    Check Write Needed (Code node)
        ├── SRE_ACTION detected → store command, send TOTP prompt
        └── no action needed  → send answer to engineer

Approval path:
    Validate Approval (validates TOTP + looks up stored command)
        ↓
    Approval Valid? (IF node)
        ├── approved → Execute Write (MCP /tools/kubectl-write)
        │                ↓ Send Execution Result
        └── denied  → Send Denial
```

---

## Nodes Explained

### Telegram Trigger
- **Type:** Telegram Trigger (webhook-based)
- Listens for incoming messages via Telegram Bot API webhook
- **Requires HTTPS** — ngrok provides the HTTPS tunnel
- Must be **Active** (not just saved) for Telegram to register the webhook

### Route Message
- **Type:** Code node
- Reads `msg.text` and checks if it starts with `/approve` or `/deny`
- Sets `route: 'approval'` or `route: 'query'` on a single output item

### Is Query? (IF node)
- Routes `route === 'query'` → K8s Assistant
- Routes everything else → Validate Approval

### K8s Assistant
- **Type:** LangChain Agent (Gemini 2.5-flash)
- **System prompt:** Neutral language — no "write", "execute", "approve". Gemini's safety training triggers on those words. Instead: "if the situation would benefit from a cluster operation, end with `SRE_ACTION: <command>`"
- Has access to two tools: `kubectl_read` and `promql`
- Connected to **Chat Memory** for conversation context

### Chat Memory
- **Type:** Window Buffer Memory
- **Session key:** `chatId` — each Telegram chat has isolated conversation history
- **Window:** 10 messages
- Allows follow-up questions: "check nginx in prod" → "what about in default?" — the agent understands "what about" refers to nginx

### Check Write Needed
- **Type:** Code node
- Parses `SRE_ACTION: <command>` from agent output using regex
- Strips `kubectl ` prefix if Gemini included it (first word in WRITE_VERBS check)
- Stores command in **workflow static data** keyed by `chatId`:
  ```js
  store.pending[chatId] = { command: cmd }
  ```
- Sends approval prompt to Telegram — engineer only needs to reply `/approve <totp-code>`

### Needs Approval? (IF node)
- Routes `needsApproval === true` → Send Approval Request
- Routes `needsApproval === false` → Send Answer

### Validate Approval
- **Type:** Code node
- Parses `/approve <6-digit-code>` or `/deny`
- Looks up `store.pending[chatId]` to retrieve the stored command
- Clears the pending entry after retrieval (prevents replay)
- Logs audit event: `{ event, user, userId, username, chatId, command, timestamp }`
- Passes TOTP code to MCP — MCP validates server-side

### Approval Valid? (IF node)
- `route === 'approve'` → Execute Write
- `route === 'deny'` → Send Denial

### Execute Write
- **Type:** HTTP Request
- POSTs to `http://mcp-server:8000/tools/kubectl-write`
- Body: `{ command, approved_by, approval_token: <totp-code> }`
- MCP validates TOTP and executes if valid

### Send Execution Result
- Shows: approver name, `@username`, Telegram user ID, command, kubectl output, timestamp

---

## TOTP 2FA Flow

```
Engineer asks: "please restart the payments deployment in prod"
    ↓
K8s Assistant investigates → confirms it's crashlooping
    ↓
AI responds + appends: SRE_ACTION: rollout restart deployment/payments-app -n prod
    ↓
Check Write Needed detects SRE_ACTION:
    - Strips "kubectl " prefix if present
    - Stores "rollout restart deployment/payments-app -n prod" in staticData[chatId]
    ↓
Telegram sends:
    ⚠️ SRE Action suggested:
    kubectl rollout restart deployment/payments-app -n prod

    🔐 Enter your 6-digit Authenticator code:
    ✅ /approve <6-digit-code>
    ❌ /deny
    ↓
Engineer opens Authy → gets current code → sends: /approve 847291
    ↓
Validate Approval retrieves stored command, passes code to MCP
    ↓
MCP validates TOTP → executes kubectl → responds with output
    ↓
Telegram confirms:
    ✅ Executed by yaniv (@yanivomc / ID: 5926921251):
    kubectl rollout restart deployment/payments-app -n prod

    deployment.apps/payments-app restarted
    🕐 Thu, 09 Apr 2026 14:23:11 GMT
```

---

## ngrok Requirement

The Telegram Trigger node registers a webhook with Telegram via n8n's `WEBHOOK_URL`. Telegram only accepts **HTTPS** webhooks. ngrok provides the HTTPS tunnel.

**Without ngrok:** Telegram refuses to register the webhook → Telegram messages don't trigger the workflow.

**After every ngrok restart:** If the URL changes (no static domain), you must deactivate + reactivate the S4 workflow in n8n to re-register the webhook with the new URL.

**Solution:** Get a free static ngrok domain at https://dashboard.ngrok.com/domains and configure it in setup.sh option 3.

---

## Conversation Memory

Chat Memory uses the Telegram `chatId` as the session key. Each user/chat has isolated memory. The memory window holds 10 message exchanges.

**Example:**
```
User: are there any pods in the prod namespace?
Bot: ❌ Namespace 'prod' doesn't exist on the cluster.

User: what about in default?
Bot: ✅ Found 3 pods running in default namespace...
```

The second message works because "what about in default?" is understood in context of the first exchange.

---

## Design Decisions

**Why store the command in staticData instead of passing it in the message?**

Early versions required the engineer to reply `/approve <token> <full-kubectl-command>`. This was error-prone (long commands, copy-paste mistakes) and exposed the token in plaintext in the chat history. By storing the command server-side in workflow static data, the engineer only needs to send `/approve <6-digit-totp>` — short, clean, secure.

**Why TOTP instead of a static token?**

A static token is a shared secret that never expires. If it's seen in logs, Telegram history, or screenshots, it's permanently compromised. TOTP codes expire every 30 seconds — even if intercepted, they're useless 30 seconds later. This is standard 2FA practice.

**Why does the AI say "SRE_ACTION:" instead of "WRITE_NEEDED:"?**

Gemini 2.5-flash has safety training that causes it to refuse when it sees words like "write", "execute", "approve" in the context of commands. Neutral terminology like `SRE_ACTION:` is treated as a structured output field, not a command execution request, so Gemini cooperates.
