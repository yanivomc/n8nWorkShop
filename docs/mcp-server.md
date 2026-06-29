# MCP Server — Technical Documentation

The MCP (Model Context Protocol) server is the **execution layer** of the workshop. It sits between n8n and the Kubernetes cluster, exposing three tools that the AI Agent can call. Write operations are gated behind TOTP 2FA — the AI can diagnose and suggest, but humans must approve before anything changes.

---

## Architecture

```
n8n AI Agent
    ↓ HTTP POST
MCP Server (FastAPI, in the clawops namespace)
    ├── /tools/kubectl-read  → free, runs any read-only kubectl command
    ├── /tools/promql        → free, runs any PromQL query against Prometheus
    ├── /tools/kubectl-write → GATED: TOTP code or static token required
    └── /incidents (CRUD)    → SQLite incident store (4-char keys)
    ↓
Kubernetes cluster (via in-cluster ServiceAccount — no kubeconfig)
Prometheus (via PROMETHEUS_URL)
```

> Auth: the MCP server uses the `mcp-server` ServiceAccount + ClusterRole
> (read-all, write only to the `workshop` namespace). Applied by
> `kubectl apply -f k8s/clawops/mcp-server/rbac.yaml`.

---

## Environment Variables

| Variable | Description |
|---|---|
| `PROMETHEUS_URL` | Internal Prometheus base **including the routePrefix**, e.g. `http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090/prometheus` (the server appends `/api/v1/query`) |
| `TOTP_SECRET` | Base32 TOTP secret for 2FA (from `mcp-secrets`; show/generate via bootstrap option 5) |
| `WRITE_APPROVAL_TOKEN` | Fallback static token if `TOTP_SECRET` not set |

> No `KUBECONFIG` — the server authenticates to the API via its in-cluster
> ServiceAccount.

---

## Tools

### Tool 1: `kubectl-read` — Free

**Endpoint:** `POST /tools/kubectl-read`

```json
{ "command": "get pods -n prod" }
```

Runs any read-only kubectl command. Write verbs (`delete`, `apply`, `create`, `run`, `rollout`, `scale`, etc.) are blocked with HTTP 403.

**Response:**
```json
{
  "output": "NAME                  READY   STATUS    ...",
  "command": "kubectl get pods -n prod",
  "exit_code": 0,
  "error": false
}
```

If kubectl returns a non-zero exit code (pod not found, namespace missing etc.) the server returns HTTP 200 with `"error": true` and the kubectl error message in `output`. This is intentional — the AI Agent can read the error and reason about it, rather than getting a generic 500.

---

### Tool 2: `promql` — Free

**Endpoint:** `POST /tools/promql`

```json
{ "query": "rate(container_cpu_usage_seconds_total[5m])" }
```

Runs any PromQL query against the configured Prometheus instance.

**Response:**
```json
{
  "result": [...],
  "query": "rate(container_cpu_usage_seconds_total[5m])"
}
```

Returns HTTP 503 if Prometheus is unreachable.

---

### Tool 3: `kubectl-write` — GATED

**Endpoint:** `POST /tools/kubectl-write`

```json
{
  "command": "rollout restart deployment/payments-app -n prod",
  "approved_by": "yaniv",
  "approval_token": "123456"
}
```

Only accepts commands whose first word is in `WRITE_VERBS`. Never called directly by the AI Agent — only called by n8n (S4) after the human sends `/approve <totp> <key>` in the dashboard chat.

> The `command` field must **not** include the `kubectl` prefix
> (e.g. `rollout restart deployment/target-app -n workshop`). S4 strips it.

**Token validation logic:**
1. If `TOTP_SECRET` is configured → validate `approval_token` as a TOTP code (±30s window)
2. Fallback → compare against static `WRITE_APPROVAL_TOKEN`
3. If neither matches → HTTP 403

**Response on success:**
```json
{
  "output": "deployment.apps/payments-app restarted",
  "command": "kubectl rollout restart deployment/payments-app -n prod",
  "approved_by": "yaniv",
  "status": "executed",
  "error": false
}
```

---

## WRITE_VERBS

Commands whose first word is in this set are treated as write operations:

```python
WRITE_VERBS = {
    "delete", "apply", "create", "replace", "patch", "run",
    "rollout", "scale", "cordon", "drain", "taint", "label", "annotate"
}
```

Any other first word → allowed through `kubectl-read`. Blocked by `kubectl-write` with HTTP 400.

---

## TOTP 2FA

### How it works

The server uses `pyotp` (Python TOTP library) to generate and validate time-based one-time passwords — the same standard as Google Authenticator and Authy.

```python
def validate_token(supplied: str) -> bool:
    if TOTP_SECRET:
        totp = pyotp.TOTP(TOTP_SECRET)
        if totp.verify(supplied, valid_window=1):  # ±30s window
            return True
    if WRITE_TOKEN and supplied == WRITE_TOKEN:
        return True
    return False
```

`valid_window=1` means the code is valid for 30 seconds before and after the current window — accounts for clock drift between the engineer's phone and the cluster.

### Generating the secret

The secret must be **valid base32** (A-Z and 2-7 only). The cluster master has no
`pip3`, so generate it inside the MCP pod where `pyotp` is installed:

```bash
kubectl exec -n clawops deployment/mcp-server -- python3 -c "import pyotp; print(pyotp.random_base32())"
# then restart so it picks up the new secret
kubectl rollout restart deployment/mcp-server -n clawops
```

`bootstrap-k8s.sh` option 5 shows the current secret + QR (generating one if missing).

### Registering in Authy

Use the QR shown by bootstrap option 5, or manually enter:
- Account: `ClawOps Workshop`
- Key: value of `TOTP_SECRET`
- Type: Time-based

---

## Audit Logging

Every write execution is logged to stdout with structured data:

```
AUDIT | WRITE_EXECUTED | approved_by=yaniv | command=kubectl rollout restart deployment/payments-app -n prod | timestamp=2026-04-09T14:23:11
```

View live:
```bash
kubectl logs -n clawops deployment/mcp-server -f | grep AUDIT
```

The `Validate Approval` node in S4 also logs an approval attempt to the n8n
execution logs (incident key + command), which together with the MCP audit line
gives a full who-approved-what-when trail keyed by the 4-char incident key.

---

## Image & operations

The MCP server runs as a Deployment in `clawops`, built from `mcp-server/Dockerfile`
and published as `yanivomc/mcp-server:latest`.

```bash
# Rebuild + redeploy (after server.py changes)
docker build -t yanivomc/mcp-server:latest ./mcp-server && \
  docker push yanivomc/mcp-server:latest && \
  kubectl rollout restart deployment/mcp-server -n clawops

# Check environment
kubectl exec -n clawops deployment/mcp-server -- env | grep -E "TOTP|WRITE|PROMETHEUS"

# Live logs
kubectl logs -n clawops deployment/mcp-server -f

# Test from inside the cluster
kubectl exec -n clawops deployment/mcp-server -- \
  curl -s -X POST http://localhost:8000/tools/kubectl-read \
  -H 'Content-Type: application/json' -d '{"command":"get pods -n workshop"}'
```

---

## Health Check

```bash
kubectl exec -n clawops deployment/mcp-server -- curl -s http://localhost:8000/health
# {"status": "ok", "tools": ["kubectl-read", "promql", "kubectl-write"]}

# Interactive API docs (through the ingress)
open http://<LB>/mcp/docs
```
