# ClawOps Workshop — Slides Brief

> **How to use this doc:** Give this entire file to Claude (or any AI) and say:
> "Build me teaching slides for Session X based on this brief."
> The AI will know the full context, content, tone, and technical depth needed.

---

## Workshop Identity

**Name:** ClawOps — AI-Assisted Incident Command  
**Audience:** DevOps/SRE engineers, intermediate K8s experience  
**Duration:** 8 hours (4 sessions × ~2h each)  
**Instructor:** Yaniv (25 years experience, DevopShift)  
**Style:** Practical, live demo-heavy, no death-by-PowerPoint. Every slide leads to hands-on work.  
**Tone:** Direct, professional, slightly dark humor about production incidents

---

## Core Thesis (say this in every session intro)

> "You don't build incident response workflows manually anymore.  
> You describe what you want, AI helps you build it.  
> But YOU still own the architecture and the approval gate."

---

## Visual Style Guidelines

- Dark theme (black/dark navy background)
- Accent color: cyan `#00D4FF` for highlights
- Code blocks: monospace, syntax-highlighted
- Diagrams: simple boxes + arrows, no clip art
- Each slide: max 5 bullet points, prefer 3
- Opening slide of each session: dramatic single-sentence hook
- Demo slides: show the actual UI screenshot, not mockups

---

## Technology Stack (reference in all slides)

| Layer | Tech |
|-------|------|
| Cluster | Kubernetes (kops, AWS, 2 nodes) |
| Workflows | n8n (self-hosted) |
| AI Model | Gemini 2.5-flash via LangChain nodes |
| Monitoring | Prometheus + Grafana + Alertmanager |
| MCP Server | FastAPI (K8s tools + Linux tools) |
| Dashboard | ClawOps (custom FastAPI + HTML) |
| Approval gate | TOTP (pyotp, Google Authenticator) |
| Alert routing | Alertmanager → n8n webhook (internal K8s DNS) |

---

## Architecture (use this diagram in S1 and reference throughout)

```
K8s Cluster
  clawops namespace:   n8n  |  mcp-server  |  clawops-dashboard
  workshop namespace:  target-app (chaos)  |  linux-mcp-server
  monitoring:          prometheus  |  grafana  |  alertmanager

ONE nginx ingress LB:
  /           → n8n
  /dashboard/ → ClawOps dashboard
  /prometheus → Prometheus
  /grafana    → Grafana
  /alertmanager/ → Alertmanager

Alert flow:
  target-app chaos → Prometheus alert → Alertmanager
  → n8n S5 webhook → AI enriches → dashboard chat
  → student approves with TOTP → kubectl-write executes
```

---

## Session 1 — Security Foundation (~60 min)

**Hook:** "Before we automate anything, let's talk about what could go wrong when AI can run kubectl."

### Topics to cover:

**1. Why TOTP over passwords**
- Passwords: stolen once, valid forever
- TOTP: valid for 30 seconds, useless after
- Demo: show Authy generating a code that expires

**2. The approval gate pattern**
- AI diagnoses, human approves, MCP executes
- No AI writes directly to production without human in the loop
- The `/approve 123456 k42a` format — TOTP + incident key

**3. RBAC for the MCP server**
- ServiceAccount `mcp-server` in `clawops` namespace
- ClusterRole: read everything, write only to `workshop` namespace
- Why: blast radius containment

**4. Alert routing — filtering at the source**
- Only `workshop="true"` alerts reach n8n
- Everything else → null receiver
- "Filter at the router, not the consumer"

**5. Namespace isolation**
- `clawops` = our tooling (n8n, MCP, dashboard) — never alerts
- `workshop` = chaos targets — always monitored
- Separation prevents false positives from our own tools

**Key diagram:** The approval gate flow — chaos → alert → AI → human → execute

**Lab:** Students scan TOTP QR code with Authy, test a TOTP code validation

---

## Session 2 — n8n AI Agent + MCP (~90 min)

**Hook:** "What if you could ask Kubernetes questions in plain English?"

### Topics to cover:

**1. n8n fundamentals (15 min)**
- Nodes: trigger → process → output
- Connections: how data flows between nodes
- The AI Agent node: LangChain under the hood
- Tool nodes vs regular nodes

**2. The MCP pattern (15 min)**
- MCP = Model Context Protocol = "tools the AI can call"
- HTTP endpoints the AI agent calls automatically
- Our tools: `kubectl_read`, `promql`, `linux_read`
- Agent decides WHICH tool to use based on the question

**3. Live demo: ask the agent questions (20 min)**
- "How many pods are running in the workshop namespace?"
- "What's the CPU usage of target-app?"
- "Are there any recent events?"
- Show the agent calling tools automatically in n8n UI

**4. S2 workflow walkthrough (10 min)**
- Chat Trigger → K8s + PromQL Agent (Gemini) → tools
- System prompt: tells the AI when to use each tool
- Memory node: keeps conversation context

**5. PromQL as a tool (15 min)**
- Why PromQL in an AI agent? Real-time metrics
- Agent knows metric names from chaos scenarios
- Example: `target_chaos_cpu_active{namespace="workshop"}`

**Key concept:** LLM as a K8s operator — describe what you want, not how to do it.

**Lab:** Students modify the system prompt to add a new behavior, observe the agent adapting

---

## Session 2.5 — Extend: Linux MCP Server Lab (~60 min)

**Hook:** "K8s metrics tell you what the cluster thinks. Linux tells you the truth."

### Topics to cover:

**1. Why Linux tools alongside K8s tools**
- K8s: pod restarted. Linux: why? (disk full? OOM? process killed?)
- Correlation: K8s says "OOMKilled" + Linux `free -m` shows 12MB left
- Adds a second layer of investigation

**2. The MCP server pattern (show the code)**
- FastAPI with POST `/tools/linux-read`
- Allowlist of safe commands: df, free, ps, netstat, uptime…
- Same response format as K8s MCP: `{output, command, error, exit_code}`

**3. Lab: build it yourself**
- Students use AI (Claude/Gemini) with our agent prompt
- AI generates: server.py, Dockerfile, deployment.yaml
- Students build the image, push, deploy
- Wire `linux_read` tool into S2 workflow

**4. Test: ask cross-layer questions**
- "Why is the node under load?" → agent calls both `kubectl_read` AND `linux_read`
- Agent correlates K8s events with OS metrics

**Key concept:** Building tools for AI is just building HTTP APIs. The AI figures out when to call them.

**Lab deliverable:** Working `linux-mcp-server` pod in workshop namespace, wired into n8n

---

## Session 4 — Human-in-the-Loop (~90 min)

**Hook:** "The AI found the problem. Now who pulls the trigger?"

### Topics to cover:

**1. The problem with full automation**
- AI is wrong sometimes. In production, "wrong" means downtime.
- The approval gate: AI recommends, human approves
- `SRE_ACTION: kubectl rollout restart deployment/target-app -n workshop`

**2. The dashboard chat (live demo)**
- Show ClawOps dashboard → CHAT tab
- Student types: "can you check why target-app is slow?"
- Agent investigates → returns with recommendation
- Shows: `⚠️ SRE Action suggested: kubectl rollout restart... ✅ /approve <totp> k42a`

**3. The TOTP approval flow (walkthrough)**
```
Student types: /approve 123456 k42a
  → dashboard → n8n S4 webhook
  → Route Message: approval detected
  → Validate Approval: splits TOTP + key
  → Fetch Incident: GET /incidents/k42a from MCP
  → Execute Write: POST /tools/kubectl-write (TOTP validated)
  → Mark Resolved: PATCH /incidents/k42a
  → Result posted back to chat
```

**4. Incident keys**
- Every action gets a 4-char key: `k42a`, `n64t`, etc.
- Stored in MCP SQLite: alertname, command, status, timestamps
- Incident Audit panel shows full history
- Keys ensure accountability: who approved what, when

**5. The `SRE_ACTION:` trick**
- Gemini refuses "execute" and "delete" commands
- `SRE_ACTION:` is neutral structured output — not a command
- Agent outputs it, workflow parses it, human approves it
- "Never fight the model's safety. Work around it."

**6. Chat is not just for approvals**
- Free-form K8s queries via chat
- Agent uses the same tools as S2
- Difference: conversation persists, history shown

**Key diagram:** Full S4 flow — chat input → route → agent → SRE_ACTION → store → approve → execute

**Lab:** Students trigger CPU stress, approve the rollout restart via TOTP

---

## Session 5 — Alert Intelligence (~90 min)

**Hook:** "Your pager goes off. It's 3am. You have 10 alerts. Which one matters?"

### Topics to cover:

**1. The problem with raw alerts**
- Alertmanager sends JSON blobs
- On-call engineer must context-switch, SSH, run kubectl
- We automate the investigation before the human is even paged

**2. The S5 flow (walkthrough)**
```
Prometheus alert fires
  → Alertmanager → n8n S5 webhook
  → Dedup Filter (ignore repeated same alert)
  → AI Agent: investigates with kubectl + promql
  → Stores incident in MCP → gets key
  → Posts to dashboard chat with AI analysis + key
  → Student reads AI report + approves fix
```

**3. The AI's investigation methodology**
- Layer-by-layer: TRAFFIC → SCHEDULING → RUNTIME → APPLICATION
- Exact metric names: `target_chaos_cpu_active`, `target_chaos_memory_bytes`, etc.
- Confidence scoring: LOW → log only, MEDIUM/HIGH → escalate
- Output: Hypothesis trail, Fault Location, Root Cause, Recommended Action

**4. What the student sees in chat**
```
🚨 TargetAppCPUStress detected!

[AI ANALYSIS]
Hypothesis: CPU stress active...
Root Cause: target_chaos_cpu_active = 1
Confidence: HIGH

Recommended: kubectl rollout restart deployment/target-app -n workshop

🔐 To approve: /approve <totp> k42a
```

**5. Why this matters**
- Alert at 3am: you already have the diagnosis when you wake up
- No cold-start investigation: AI did it while you were sleeping
- You just read the report and approve or deny
- Audit trail: incident key persists who approved what

**6. Monitoring architecture**
- All monitoring services ClusterIP — never exposed directly
- Alertmanager sends to n8n via internal K8s DNS
- Zero external dependencies for the alert path

**Key demo:** Trigger CPU sustained → watch dashboard chat light up with AI analysis in real-time

**Lab:** Students modify S5 AI prompt to add a new investigation step

---

## Capstone / Lab Session — Build Your Own Tool (~60 min)

**Hook:** "You've seen what we built. Now build something the AI has never seen before."

### Topics to cover:

**1. The pattern is simple**
- FastAPI + POST endpoint + allowlist + subprocess
- Register it as a tool node in n8n
- Write a tool description — that's how the AI knows when to use it
- Ship it in a Dockerfile

**2. What students can build**
Ideas to offer:
- `helm_read` — run safe helm commands (list, status, get values)
- `log_analyzer` — tail last N lines of a pod log, return summarized
- `network_check` — curl/wget health checks from inside the cluster
- `git_status` — check what version of code is deployed (git describe)

**3. Wire it in**
- Add HTTP Request Tool node in n8n → connect to agent
- Update system prompt: "You have a new tool: X. Use it when Y."
- Test: ask the agent a question that should trigger the new tool

**Key concept:** "Every new capability is just a new HTTP endpoint. AI figures out the rest."

---

## Slide Templates Needed (per session)

For each session, produce these slide types:

1. **Session intro** — hook quote, what you'll learn, prerequisites
2. **Architecture diagram** — relevant subset for this session
3. **Concept slides** (2–4 per topic) — title + 3 bullets + diagram or code snippet
4. **Demo slide** — "LIVE DEMO" banner + what to show + expected outcome
5. **How it works** — flow diagram for the key workflow
6. **Code spotlight** — key code snippet with callouts (not too long)
7. **Lab slide** — what to do, time limit, success criteria
8. **Recap** — 3 things you learned this session
9. **Bridge** — how this connects to next session

---

## Key Quotes / Soundbites (use these verbatim in slides)

- "Never act on a single signal."
- "Filter at the router, not the consumer."
- "AI diagnoses. Human approves. MCP executes."
- "The blast radius of a wrong kubectl is contained by the approval gate."
- "SRE_ACTION is not a command. It's structured output. Gemini doesn't know the difference."
- "You still own the architecture. AI just helps you build it faster."
- "The incident key is your audit trail. You can't approve what you can't trace."

---

## What Already Exists (don't rebuild these)

Slide decks already produced (in `/mnt/user-data/outputs/` or on disk):
- `clawops-section1.pptx` — Opening & Framing
- `clawops-section2.pptx` — n8n Fundamentals
- `clawops-section3.pptx` — Prometheus Alerts to Action (S5)
- `clawops-section4.pptx` — Human-in-the-Loop (S4)
- `clawops-setup-guide.pptx` — Student Setup Guide
- `clawops-security.pptx` — Security Overview

**Gaps to fill:**
- S2.5 — Linux MCP Lab (new)
- Updated S4 to reflect dashboard chat (not Telegram)
- Updated S5 to reflect dashboard chat (not Telegram)
- Capstone session
- Day 2 recap / closing

---

## Important: What Changed from Original Design

The original design used **Telegram** for all human interaction. This has been replaced:

| Old | New |
|-----|-----|
| Telegram bot | ClawOps dashboard chat (SSE) |
| ngrok tunnel | Internal K8s DNS |
| Docker Compose | Kubernetes (all-in-K8s) |
| EC2 IPs hardcoded | Single ingress LB, auto-detected |
| Student setup.sh | bootstrap-k8s.sh run |
| S3 Telegram | Replaced by S5 (dashboard chat) |

**Update any existing slides** that show Telegram to show the dashboard chat instead.
