# Lab — Extend the S2.5 Agent

**Workflow:** `S2.5 - Linux + K8s Agent`
**Two short labs · ~20 min total · all done in the n8n UI — no code, no deploys**

You already loaded **S2.5** and watched it answer K8s, Linux, and PromQL questions.
Now you'll change it yourself. Two labs, two levers:

- **Lab A — shape *how* the agent behaves** (edit its instructions)
- **Lab B — give the agent a *new ability*** (add a tool node)

> **Before you start:** open `S2.5 - Linux + K8s Agent` in n8n and confirm the chat
> works — ask *"how many pods are in the workshop namespace?"* and get an answer.

---

## Lab A — Shape the Agent's Behavior  ⏱ ~10 min

**Goal:** prove you steer the AI in plain English. The system prompt is policy — no code.

### Steps

1. Open the **S2.5** workflow and **double-click the `K8s + Linux Agent` node**.
2. Find the **System Message** field (under **Options** → *System Message*). This is the
   instruction block the agent follows. Scroll to the `## Response style:` section.

   📸 *[screenshot: the K8s + Linux Agent node with the System Message open]*

3. Add **one** new rule. Pick a flavour and paste it as a new line under `## Response style:`

   **Option 1 — a risk verdict (recommended):**
   ```
   - Always end your answer with a one-line risk verdict:
     🟢 safe to ignore  /  🟡 worth watching  /  🔴 act now
   ```

   **Option 2 — a guardrail:**
   ```
   - Only investigate the `workshop` namespace. If asked about `clawops`,
     `kube-system`, or `monitoring`, politely refuse and say it is out of scope.
   ```

   **Option 3 — formatting:**
   ```
   - When you list pods or namespaces, always format them as a markdown table.
   ```

4. Click **Save** (top-right). No need to re-import anything.
5. Open the **chat** and ask a question, e.g. *"list the pods in the workshop namespace."*

### ✅ Success
The answer now follows your new rule (e.g. ends with a 🟢/🟡/🔴 verdict, or refuses
out-of-scope namespaces, or returns a table).

### 🔁 Try this
- Swap in a **second** rule and re-ask — feel how fast behaviour changes.
- Add a contradictory rule and watch the agent get confused — prompts are powerful *and*
  fragile.

### 💡 What you learned
The system prompt **is** the agent's policy. You just added a guardrail / behaviour with
zero code — the same trick that later makes the AI emit a safe `SRE_ACTION` instead of
running a command.

---

## Lab B — Give the Agent a New Tool  ⏱ ~10 min

**Goal:** prove that a new capability = **one tool node + a good description**. The agent
decides when to use it. *(No code/deploy — you're pointing at an MCP endpoint that already
exists: `GET /incidents`.)*

You'll add an **`incidents_read`** tool so the agent can answer *"what incidents have we
had recently?"*

### Steps

1. In the **S2.5** workflow, click the **`kubectl_read`** node once to select it, then
   **copy + paste** it (Cmd/Ctrl-C, Cmd/Ctrl-V). A duplicate appears.
2. **Rename** the new node to **`incidents_read`** (double-click its title).
3. Double-click `incidents_read` and change these fields:

   | Field | Set it to |
   |---|---|
   | **Method** | `GET` |
   | **URL** | `http://mcp-server.clawops.svc.cluster.local:8000/incidents?limit=20` |
   | **Send Body** | **OFF** (a GET has no body — turn off the `{ "command": ... }` body) |
   | **Tool Description** | *List recent incidents recorded by the system: alertname, namespace, pod, command, status, and time. Use when the user asks about past incidents, what was remediated, or open issues.* |

   📸 *[screenshot: the incidents_read node settings — GET + URL + description]*

   > The **Tool Description** is how the AI knows *when* to call this tool — write it for the model, not for yourself.

4. **Wire it to the agent.** Drag from the small connector at the **bottom of
   `incidents_read`** to the **`Tool`** port of the **`K8s + Linux Agent`** node
   (the same port `kubectl_read`, `promql`, and `linux_read` plug into).

   📸 *[screenshot: incidents_read connected to the agent's tool port]*

5. **Tell the agent it exists.** Open the `K8s + Linux Agent` node → **System Message**,
   and add a 4th tool under the tools list:
   ```
   4. incidents_read — list recent incidents from the incident store
      (alertname, namespace, pod, command, status, time)
   ```
6. Click **Save**.
7. Open the **chat** and ask: **"What incidents have we had recently?"**
   (also try *"any incidents in the workshop namespace?"*)

### ✅ Success
The agent calls **`incidents_read`** and summarises the incident list. *(If none exist yet,
it correctly says "no incidents recorded" — the tool still worked. You'll generate real
ones in the S4/S5 labs.)*

### 🔁 Try this
- Ask *"group the incidents by namespace"* — same tool, the agent does the reasoning.
- Open the **execution** (the run that just happened) and expand `incidents_read` to see
  the exact HTTP call and JSON the agent received.

### 💡 What you learned
Adding an AI capability is just adding an **HTTP endpoint as a tool node** and describing
it. This is *exactly* how the kubectl / promql / linux tools were built — and how every new
power you give the agent works.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Agent ignores the new tool | Check the **Tool Description** isn't empty, the node is **connected to the agent's Tool port**, and the system prompt mentions it. |
| `incidents_read` errors / 404 | Re-check the **URL** spelling and that **Method = GET**. |
| Tool sends a weird body | Make sure **Send Body is OFF** on `incidents_read` (a leftover `{command}` body from the copy). |
| Behaviour rule had no effect | Did you click **Save**? Re-open the chat and ask a fresh question (memory keeps old context). |

## Recap

You used the **two levers** every AI-agent workflow gives you:
- **Lab A — the prompt** controls *how* it behaves (policy, guardrails, format).
- **Lab B — the tools** control *what* it can do (each tool = one HTTP endpoint + a description).

These are the same two levers you'll use to build the alert-investigation and approval
workflows (S4 / S5) next.
