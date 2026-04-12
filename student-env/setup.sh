#!/bin/bash
# n8n Workshop — Student Setup & Menu
# Usage: ./setup.sh

ENV_FILE="$(dirname "$0")/.env"
KUBE_CONFIG="$HOME/.kube/config"

# ── Colours ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "${RED}✗${NC} $1"; }
hdr()  { echo -e "\n${BOLD}${CYAN}$1${NC}"; echo "────────────────────────────────────────"; }

# ── Helpers ───────────────────────────────────────────────────────────
load_env() { [ -f "$ENV_FILE" ] && source "$ENV_FILE" 2>/dev/null || true; }

save_env_var() {
  local key=$1 val=$2
  # Always single-quote values to prevent shell interpretation
  local quoted="'${val//'/\'\'\'\'}'"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${quoted}|" "$ENV_FILE"
  else
    echo "${key}=${quoted}" >> "$ENV_FILE"
  fi
}

kubectl_works() { kubectl get nodes &>/dev/null; }

cluster_host_from_kubeconfig() {
  grep -oP 'https://\K[^/:]+' "$KUBE_CONFIG" 2>/dev/null | head -1
}

patch_hosts() {
  local host=$1 ip=$2
  sudo sed -i "/$host/d" /etc/hosts
  echo "$ip $host" | sudo tee -a /etc/hosts > /dev/null
  ok "Patched /etc/hosts: $ip $host"
}

# ── Install kubectl ───────────────────────────────────────────────────
install_kubectl() {
  hdr "Installing kubectl"
  if command -v kubectl &>/dev/null; then
    ok "kubectl already installed: $(kubectl version --client --short 2>/dev/null | head -1)"
    return
  fi
  local ver
  ver=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
  ok "kubectl ${ver} installed"
}

# ── Setup cluster ─────────────────────────────────────────────────────
setup_cluster() {
  hdr "Cluster Setup"
  load_env

  if kubectl_works; then
    ok "kubectl already has cluster access"
    echo -n "  Re-configure cluster? [y/N]: "
    read ans; [[ "$ans" =~ ^[Yy]$ ]] || return
  fi

  echo -n "  Master node public IP: "
  read MASTER_IP
  echo -n "  Kubeconfig presigned S3 URL: "
  read KUBECONFIG_URL

  [[ -z "$MASTER_IP" || -z "$KUBECONFIG_URL" ]] && { err "Both values required."; return; }

  install_kubectl

  mkdir -p ~/.kube
  curl -sL "$KUBECONFIG_URL" -o "$KUBE_CONFIG"
  chmod 600 "$KUBE_CONFIG"
  ok "kubeconfig downloaded"

  CLUSTER_HOST=$(cluster_host_from_kubeconfig)
  [[ -z "$CLUSTER_HOST" ]] && { warn "Could not parse cluster host from kubeconfig"; CLUSTER_HOST="api.cluster.local"; }
  ok "Cluster host: $CLUSTER_HOST"

  patch_hosts "$CLUSTER_HOST" "$MASTER_IP"

  save_env_var "MASTER_IP" "$MASTER_IP"
  save_env_var "CLUSTER_HOST" "$CLUSTER_HOST"

  echo ""
  if kubectl_works; then
    ok "Cluster connection verified!"
    kubectl get nodes
  else
    err "Cannot connect to cluster. Check security groups (port 443 from this IP)."
  fi
}

# ── Configure keys ────────────────────────────────────────────────────
configure_keys() {
  hdr "Configure API Keys & Tokens"
  load_env

  echo -n "  Gemini API key [${GEMINI_API_KEY:+set, enter to keep}]: "
  read val; [[ -n "$val" ]] && { save_env_var "GEMINI_API_KEY" "$val"; ok "Gemini key saved"; } || ok "Kept existing"

  echo -n "  Telegram bot token [${TELEGRAM_BOT_TOKEN:+set, enter to keep}]: "
  read val; [[ -n "$val" ]] && { save_env_var "TELEGRAM_BOT_TOKEN" "$val"; ok "Telegram token saved"; } || ok "Kept existing"

  echo -n "  Telegram chat ID [${TELEGRAM_CHAT_ID:+set, enter to keep}]: "
  read val; [[ -n "$val" ]] && { save_env_var "TELEGRAM_CHAT_ID" "$val"; ok "Chat ID saved"; } || ok "Kept existing"

  # Auto-generate write approval token if not set
  # Write approval token kept for fallback — primary auth is TOTP (configured below)
  if [[ -z "$WRITE_APPROVAL_TOKEN" ]]; then
    TOKEN=$(openssl rand -hex 32)
    save_env_var "WRITE_APPROVAL_TOKEN" "$TOKEN"
    ok "Write approval token generated (fallback)"
  fi

  # Auto-detect EC2 public IP from AWS instance metadata
  DETECTED_IP=$(curl -sf --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
  [[ -n "$DETECTED_IP" && -z "$EC2_PUBLIC_IP" ]] && { save_env_var "EC2_PUBLIC_IP" "$DETECTED_IP"; EC2_PUBLIC_IP="$DETECTED_IP"; ok "EC2 IP auto-detected: $EC2_PUBLIC_IP"; }
  [[ -n "$DETECTED_IP" && -n "$EC2_PUBLIC_IP" && "$DETECTED_IP" != "$EC2_PUBLIC_IP" ]] && warn "  New EC2 IP detected ($DETECTED_IP) — differs from saved ($EC2_PUBLIC_IP)"
  echo -n "  EC2 public IP [${EC2_PUBLIC_IP:-could not auto-detect, enter manually}]: "
  read val
  if [[ -n "$val" ]]; then
    save_env_var "EC2_PUBLIC_IP" "$val"; ok "EC2 IP saved: $val"
  elif [[ -n "$EC2_PUBLIC_IP" ]]; then
    ok "EC2 IP confirmed: $EC2_PUBLIC_IP"
  else
    err "EC2 IP not set — webhook URLs will be broken. Re-run option 3."
  fi

  # TOTP 2FA setup — generate using MCP container (has pyotp installed)
  if [[ -z "$TOTP_SECRET" ]]; then
    echo ""
    ok "Generating TOTP secret for 2FA approval gate..."
    # Build MCP container first so pyotp is available
    cd "$(dirname "$0")"
    docker compose build mcp-server --quiet 2>/dev/null
    TOTP_SECRET=$(docker run --rm student-env-mcp-server python3 -c "import pyotp; print(pyotp.random_base32())" 2>/dev/null)
    if [[ -z "$TOTP_SECRET" ]]; then
      err "Could not generate TOTP secret — is Docker running?"
      return
    fi
    save_env_var "TOTP_SECRET" "$TOTP_SECRET"
    # Restart MCP with new secret
    docker rm -f mcp-server 2>/dev/null || true
    docker compose up -d mcp-server
    echo ""
    echo -e "  ${CYAN}📱 Add this key to Authy or Google Authenticator:${NC}"
    echo -e "  ${BOLD}  Account: ClawOps Workshop${NC}"
    echo -e "  ${BOLD}  Key:     ${TOTP_SECRET}${NC}"
    echo -e "  ${CYAN}  QR Code: https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=otpauth%3A%2F%2Ftotp%2FClawOps%2520Workshop%3Fsecret%3D${TOTP_SECRET}%26issuer%3Dn8nWorkshop${NC}"
    echo ""
    ok "MCP server restarted with TOTP support"
  else
    ok "TOTP secret already configured (use Authy/Google Auth to get codes)"
    echo -e "  ${CYAN}  Key: ${TOTP_SECRET}${NC}"
    echo -e "  ${CYAN}  QR:  https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=otpauth%3A%2F%2Ftotp%2FClawOps%2520Workshop%3Fsecret%3D${TOTP_SECRET}%26issuer%3Dn8nWorkshop${NC}"
  fi

  echo -n "  ngrok static domain (optional, get free one at dashboard.ngrok.com/domains) [${NGROK_DOMAIN:-not set}]: "
  read val; [[ -n "$val" ]] && { save_env_var "NGROK_DOMAIN" "$val"; ok "ngrok domain saved"; } || ok "Kept existing"

  echo -n "  n8n admin password [${N8N_PASSWORD:-changeme123}]: "
  read val
  if [[ -n "$val" ]]; then
    save_env_var "N8N_PASSWORD" "$val"
    save_env_var "N8N_USER" "admin"
    ok "n8n credentials saved"
  else
    save_env_var "N8N_PASSWORD" "${N8N_PASSWORD:-changeme123}"
    save_env_var "N8N_USER" "admin"
    ok "Kept existing n8n credentials"
  fi
}

# ── Show status ───────────────────────────────────────────────────────
show_status() {
  hdr "Environment Status"
  load_env

  # Cluster
  if kubectl_works; then
    ok "Cluster access (kubectl)"
    kubectl get nodes --no-headers 2>/dev/null | awk '{printf "   %-40s %s\n", $1, $2}'
  else
    err "No cluster access"
  fi

  # Docker
  if docker info &>/dev/null; then
    ok "Docker running"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q n8n; then
      ok "n8n container running"
    else
      warn "n8n container not running (docker compose up -d)"
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q mcp-server; then
      ok "MCP server running"
    else
      warn "MCP server not running"
    fi
  else
    err "Docker not running"
  fi

  # MCP health
  if curl -sf http://localhost:8000/health &>/dev/null; then
    ok "MCP server responding"
  else
    warn "MCP server not responding on :8000"
  fi

  echo ""
  echo "  Keys:"
  [[ -n "$GEMINI_API_KEY" ]]       && ok "  Gemini API key set"       || warn "  Gemini API key missing"
  [[ -n "$TELEGRAM_BOT_TOKEN" ]]   && ok "  Telegram token set"       || warn "  Telegram token missing"
  [[ -n "$TELEGRAM_CHAT_ID" ]]     && ok "  Telegram chat ID set"     || warn "  Telegram chat ID missing"
  [[ -n "$WRITE_APPROVAL_TOKEN" ]] && ok "  Write approval token set" || warn "  Write approval token missing"
  [[ -n "$EC2_PUBLIC_IP" ]]        && ok "  EC2 public IP: $EC2_PUBLIC_IP" || warn "  EC2 public IP missing"
}

# ── Start/stop stack ──────────────────────────────────────────────────
start_stack() {
  hdr "Starting n8n + MCP Server"
  cd "$(dirname "$0")"
  load_env

  # ── Pre-flight checks ────────────────────────────────────────────────
  local ok=true
  echo "  Checking requirements..."

  [[ -z "$EC2_PUBLIC_IP" ]]    && { err "EC2_PUBLIC_IP not set  → run option 3 (Configure API keys)"; ok=false; }
  [[ -z "$GEMINI_API_KEY" ]]   && { warn "GEMINI_API_KEY not set → run option 3 (AI Agent will not work)"; }
  [[ -z "$PROMETHEUS_URL" ]]   && { err "PROMETHEUS_URL not set  → run option 4 (Install Prometheus + Grafana) first"; ok=false; }
  [[ -z "$TOTP_SECRET" ]]      && { warn "TOTP_SECRET not set    → run option 3 (approval gate needs 2FA)"; }
  [[ -z "$WRITE_APPROVAL_TOKEN" ]] && { warn "WRITE_APPROVAL_TOKEN not set → run option 3"; }

  # Check kubeconfig
  if [[ ! -f "${KUBECONFIG_PATH:-$HOME/.kube/config}" ]]; then
    err "kubeconfig not found at ${KUBECONFIG_PATH:-$HOME/.kube/config} → run option 2 (Re-configure cluster)"
    ok=false
  fi

  if [[ "$ok" == "false" ]]; then
    echo ""
    err "Pre-flight failed — fix the errors above before starting the stack."
    return
  fi
  echo ""

  docker compose up -d --build
  echo ""
  ok "Stack started"
  # Verify TOTP is configured
  if [[ -z "$TOTP_SECRET" ]]; then
    warn "TOTP_SECRET not set — run option 3 to configure 2FA for the approval gate"
  else
    ok "TOTP 2FA active — use Authy/Google Authenticator for approvals"
  fi
  echo "  n8n:  http://${EC2_PUBLIC_IP}:5678"
  echo "  MCP:  http://localhost:8000/docs"
  echo ""
  # Check if ngrok is running
  NGROK_URL=$(curl -sf http://localhost:4040/api/tunnels 2>/dev/null | python3 -c "
import sys,json
data=json.load(sys.stdin)
for t in data.get('tunnels',[]):
    if t.get('proto')=='https': print(t['public_url']); break
" 2>/dev/null)
  if [[ -n "$NGROK_URL" ]]; then
    ok "ngrok tunnel active: $NGROK_URL"
  else
    warn "ngrok not running — required for S4 Telegram Trigger."
    warn "Run option 10 before activating the S4 workflow."
  fi
}

stop_stack() {
  hdr "Stopping Stack"
  cd "$(dirname "$0")"
  docker compose down
  ok "Stack stopped"
}

# ── Install Prometheus + Grafana (placeholder for next sprint) ────────
install_monitoring() {
  hdr "Install Prometheus + Grafana"
  load_env

  if ! kubectl_works; then
    err "No cluster access — run cluster setup first"
    return
  fi

  if [[ -z "$EC2_PUBLIC_IP" ]]; then
    err "EC2_PUBLIC_IP not set — run option 3 first"
    return
  fi

  # Install Helm if missing
  if ! command -v helm &>/dev/null; then
    echo "  Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    ok "Helm installed"
  else
    ok "Helm: $(helm version --short 2>/dev/null)"
  fi

  echo "  Adding prometheus-community repo..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null
  helm repo update &>/dev/null
  ok "Helm repo ready"

  # Detect if EC2 IP changed since last helm install
  LAST_INSTALLED_IP=$(helm get values monitoring -n monitoring 2>/dev/null | grep -oP 'EC2_PUBLIC_IP_PLACEHOLDER: \K\S+' || true)
  CURRENT_WEBHOOK=$(helm get values monitoring -n monitoring 2>/dev/null | grep -oP '(?<=url: "http://)([0-9.]+)(?=:5678)' || true)
  if [[ -n "$CURRENT_WEBHOOK" && "$CURRENT_WEBHOOK" != "$EC2_PUBLIC_IP" ]]; then
    warn "EC2 IP changed: old=$CURRENT_WEBHOOK → new=$EC2_PUBLIC_IP"
    warn "Re-applying Alertmanager webhook with new IP..."
  elif [[ -n "$CURRENT_WEBHOOK" && "$CURRENT_WEBHOOK" == "$EC2_PUBLIC_IP" ]]; then
    ok "EC2 IP unchanged ($EC2_PUBLIC_IP) — upgrading to apply any rule changes"
  else
    ok "First install — Alertmanager webhook → http://${EC2_PUBLIC_IP}:5678"
  fi

  # ℹ️  Alertmanager uses EC2 IP directly (NOT ngrok) — more reliable
  echo "  ℹ️  Alertmanager → n8n: direct EC2 IP (ngrok is for Telegram only)"

  # Patch alertmanager webhook URL in values file
  VALUES_FILE="$(dirname "$0")/../k8s/monitoring/prometheus-values.yaml"
  PATCHED_FILE="/tmp/prometheus-values-patched.yaml"
  sed "s|EC2_PUBLIC_IP_PLACEHOLDER|${EC2_PUBLIC_IP}|g" "$VALUES_FILE" > "$PATCHED_FILE"
  ok "Alertmanager webhook → http://${EC2_PUBLIC_IP}:5678/webhook/prometheus-alert-s5"

  echo "  Installing kube-prometheus-stack (AWS LoadBalancer)..."
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f "$PATCHED_FILE" \
    --timeout 5m \
    --wait

  echo ""
  ok "Monitoring stack installed"
  echo ""

  # Wait for LB hostnames to be assigned
  echo "  Waiting for LoadBalancer addresses (up to 60s)..."
  for i in $(seq 1 12); do
    PROM_HOST=$(kubectl get svc -n monitoring monitoring-kube-prometheus-prometheus \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    GRAFANA_HOST=$(kubectl get svc -n monitoring monitoring-grafana \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    [[ -n "$PROM_HOST" && -n "$GRAFANA_HOST" ]] && break
    sleep 5
  done

  echo ""
  if [[ -n "$PROM_HOST" ]]; then
    ok "Prometheus: http://${PROM_HOST}:9090"
    save_env_var "PROMETHEUS_URL" "http://${PROM_HOST}:9090"
  else
    warn "Prometheus LB pending — check: kubectl get svc -n monitoring"
    warn "Re-run option 4 once the LB is ready, then restart the stack (option 5)."
  fi

  if [[ -n "$GRAFANA_HOST" ]]; then
    ok "Grafana:    http://${GRAFANA_HOST}  (admin / workshop123)"
    save_env_var "GRAFANA_URL" "http://${GRAFANA_HOST}"
  else
    warn "Grafana LB pending — check: kubectl get svc -n monitoring"
  fi

  ALERTMANAGER_HOST=$(kubectl get svc -n monitoring monitoring-kube-prometheus-alertmanager     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [[ -n "$ALERTMANAGER_HOST" ]]; then
    ok "Alertmanager: http://${ALERTMANAGER_HOST}:9093"
    save_env_var "ALERTMANAGER_URL" "http://${ALERTMANAGER_HOST}:9093"
  else
    warn "Alertmanager LB pending — check: kubectl get svc -n monitoring"
  fi

  echo ""
  kubectl get pods -n monitoring

  # Reload MCP server with updated PROMETHEUS_URL
  # Must rm the container — restart alone does not reload .env variables
  if docker ps -q -f name=mcp-server | grep -q .; then
    echo ""
    echo "  Reloading MCP server with new PROMETHEUS_URL..."
    cd "$(dirname "$0")"
    docker rm -f mcp-server
    docker compose up -d mcp-server
    ok "MCP server reloaded — Prometheus URL active"
  fi
}

# ── Validate setup ────────────────────────────────────────────────────
# ── Validate setup ────────────────────────────────────────────────────
validate_setup() {
  hdr "Validation"
  load_env

  local pass=0 fail=0 warn_count=0

  check_pass() { ok "$1"; ((++pass)); }
  check_fail() { err "$1"; ((++fail)); }

  mcp_read_check() {
    local label=$1 cmd=$2
    local out
    out=$(curl -sf -X POST http://localhost:8000/tools/kubectl-read \
      -H "Content-Type: application/json" \
      -d "{\"command\":\"${cmd}\"}" 2>/dev/null)
    if echo "$out" | grep -q '"output"'; then check_pass "$label"; else check_fail "$label"; fi
  }

  mcp_write_blocked_check() {
    local out
    out=$(curl -s -X POST http://localhost:8000/tools/kubectl-read \
      -H "Content-Type: application/json" \
      -d '{"command":"delete pod test"}' 2>/dev/null)
    if echo "$out" | grep -q '"detail"'; then check_pass "MCP write tool blocked"; else check_fail "MCP write tool blocked"; fi
  }

  pod_warn_check() {
    local label=$1 ns=$2 selector=$3
    if kubectl get pods -n "$ns" -l "$selector" 2>/dev/null | grep -q Running; then
      ok "$label"; ((++pass))
    else
      warn "$label (optional)"; ((++warn_count))
    fi
  }

  lb_warn_check() {
    local label=$1 url=$2
    if [[ -n "$url" ]] && curl -sf "$url" &>/dev/null; then
      ok "$label"; ((++pass))
    else
      warn "$label (optional)"; ((++warn_count))
    fi
  }

  # ── Core checks ───────────────────────────────────────
  echo -e "  ${BOLD}Core${NC}"

  kubectl get nodes &>/dev/null     && check_pass "kubectl cluster access"    || check_fail "kubectl cluster access"
  docker info &>/dev/null           && check_pass "Docker daemon"             || check_fail "Docker daemon"
  docker inspect n8n &>/dev/null    && check_pass "n8n container running"     || check_fail "n8n container running"
  docker inspect mcp-server &>/dev/null && check_pass "MCP container running" || check_fail "MCP container running"
  curl -sf http://localhost:8000/health &>/dev/null && check_pass "MCP health endpoint" || check_fail "MCP health endpoint"

  mcp_read_check "MCP kubectl-read works" "get nodes"
  mcp_read_check "MCP can reach K8s"     "get pods -n kube-system"
  mcp_write_blocked_check

  [[ -n "$GEMINI_API_KEY" ]]       && check_pass "Gemini API key set"       || check_fail "Gemini API key set"
  [[ -n "$TELEGRAM_BOT_TOKEN" ]]   && check_pass "Telegram token set"       || check_fail "Telegram token set"
  [[ -n "$TELEGRAM_CHAT_ID" ]]     && check_pass "Telegram chat ID set"     || check_fail "Telegram chat ID set"
  [[ -n "$WRITE_APPROVAL_TOKEN" ]] && check_pass "Write approval token set" || check_fail "Write approval token set"

  # ── Monitoring checks (Sessions 5-8) ─────────────────
  echo ""
  echo -e "  ${BOLD}Monitoring (needed for Sessions 5-8)${NC}"

  PROM_HOST=$(kubectl get svc -n monitoring monitoring-kube-prometheus-prometheus \
    -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null)
  GRAFANA_HOST=$(kubectl get svc -n monitoring monitoring-grafana \
    -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null)

  pod_warn_check "Prometheus pod running"   monitoring "app.kubernetes.io/name=prometheus"
  pod_warn_check "Grafana pod running"      monitoring "app.kubernetes.io/name=grafana"
  pod_warn_check "Alertmanager pod running" monitoring "app.kubernetes.io/name=alertmanager"
  lb_warn_check  "Prometheus LB reachable"  "http://${PROM_HOST}:9090/-/healthy"
  lb_warn_check  "Grafana LB reachable"     "http://${GRAFANA_HOST}/api/health"

  [[ -n "$PROM_HOST" ]]    && echo -e "  ${CYAN}→ Prometheus: http://${PROM_HOST}:9090${NC}"
  [[ -n "$GRAFANA_HOST" ]] && echo -e "  ${CYAN}→ Grafana:    http://${GRAFANA_HOST}  (admin/workshop123)${NC}"

  # ── Summary ───────────────────────────────────────────
  echo ""
  echo "  ──────────────────────────────────"
  echo "  Passed: ${pass}  Failed: ${fail}  Optional warnings: ${warn_count}"
  if [[ $fail -eq 0 && $warn_count -eq 0 ]]; then
    ok "Everything ready — let the workshop begin!"
  elif [[ $fail -eq 0 ]]; then
    ok "Core ready. Install monitoring (option 6) before Session 5."
  else
    err "${fail} core check(s) failed — fix before starting."
  fi
}

# ── Test Telegram bot ─────────────────────────────────────────────────
test_telegram() {
  hdr "Test Telegram Bot"
  load_env

  if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    err "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set — run option 3 first"
    return
  fi

  echo "  Sending test message..."
  RESPONSE=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=🚀 Workshop bot is alive! MCP + n8n ready." 2>&1)

  if echo "$RESPONSE" | grep -q '"ok":true'; then
    ok "Message sent! Check your Telegram."
  elif echo "$RESPONSE" | grep -q "chat not found"; then
    err "Chat not found — you need to start the bot first."
    echo ""
    echo -e "  ${BOLD}Fix (30 seconds):${NC}"
    echo "    1. Open Telegram on your phone"
    echo "    2. Search for your bot by username"
    echo "    3. Tap START or send /start"
    echo "    4. Re-run this test (option 8)"
    echo ""
    echo "  Why: Telegram blocks bots from messaging users who never"
    echo "  initiated contact. /start unlocks the conversation."
  else
    err "Failed to send message."
    echo "  Response: $RESPONSE"
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Verify token: https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/getMe"
    echo "    2. Check your chat ID via @userinfobot"
    echo "    3. Make sure you sent /start to your bot"
    echo ""
    echo "  Full guide: ~/n8nWorkShop/labs/telegram-bot-setup.md"
  fi
}



# ── Generate credentials file ─────────────────────────────────────────
generate_credentials() {
  load_env
  local outfile="$HOME/n8nWorkShop/CREDENTIALS.md"

  local EC2_IP
  EC2_IP=$(curl -sf http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "${EC2_PUBLIC_IP}")

  local PROM_HOST GRAFANA_HOST ALERTMANAGER_HOST
  PROM_HOST=$(kubectl get svc -n monitoring monitoring-kube-prometheus-prometheus     -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null)
  ALERTMANAGER_HOST=$(kubectl get svc -n monitoring monitoring-kube-prometheus-alertmanager     -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null)
  GRAFANA_HOST=$(kubectl get svc -n monitoring monitoring-grafana     -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null)

  cat > "$outfile" << MDEOF
# Workshop Credentials & Endpoints

> ⚠️  This file is auto-generated by setup.sh — do NOT commit to git.
> Re-run option 9 to refresh after environment changes.

Generated: $(date)

---

## Access Endpoints

| Service | URL | User | Password |
|---------|-----|------|----------|
| **n8n** | http://${EC2_IP}:5678 | admin | ${N8N_PASSWORD} |
| **MCP Server** | http://${EC2_IP}:8000/docs | — | — |
| **Terminal** | http://${EC2_IP}:5000 | — | — |
| **Prometheus** | http://${PROM_HOST}:9090 | — | — |
| **Grafana** | http://${GRAFANA_HOST} | admin | workshop123 |
| **Alertmanager** | http://${ALERTMANAGER_HOST}:9093 | — | — |

---

## API Keys & Tokens

| Key | Value |
|-----|-------|
| Gemini API Key | \`${GEMINI_API_KEY}\` |
| Telegram Bot Token | \`${TELEGRAM_BOT_TOKEN}\` |
| Telegram Chat ID | \`${TELEGRAM_CHAT_ID}\` |
| Write Approval Token | \`${WRITE_APPROVAL_TOKEN}\` |

---

## MCP Tools (curl reference)

\`\`\`bash
# Read — kubectl get
curl -s -X POST http://${EC2_IP}:8000/tools/kubectl-read \
  -H "Content-Type: application/json" \
  -d '{"command":"get pods -A"}'

# PromQL query
curl -s -X POST http://${EC2_IP}:8000/tools/promql \
  -H "Content-Type: application/json" \
  -d '{"query":"up"}'

# Write — only after Telegram approval (token required)
curl -s -X POST http://${EC2_IP}:8000/tools/kubectl-write \
  -H "Content-Type: application/json" \
  -d '{"command":"rollout restart deployment/payments -n prod","approved_by":"you","approval_token":"${WRITE_APPROVAL_TOKEN}"}'
\`\`\`

---

## Lab Scenarios

| # | Scenario | Inject | Cleanup |
|---|----------|--------|---------|
| 01 | CrashLoopBackOff | \`k8s/scenarios/01-crashloop/inject.sh\` | \`cleanup.sh\` |
| 02 | OOMKill | \`k8s/scenarios/02-oom-kill/inject.sh\` | \`cleanup.sh\` |
| 03 | Pending Pods | \`k8s/scenarios/03-pending-pods/inject.sh\` | \`cleanup.sh\` |
| 04 | ImagePullBackOff | \`k8s/scenarios/04-failed-deployment/inject.sh\` | \`cleanup.sh\` |
| 05 | Flapping Alert | \`k8s/scenarios/05-flapping-alert/inject.sh\` | — |

MDEOF

  ok "Credentials file written: $outfile"
  echo ""
  echo -e "  ${CYAN}→ n8n:        http://${EC2_IP}:5678${NC}"
  echo -e "  ${CYAN}→ Prometheus: http://${PROM_HOST}:9090${NC}"
  echo -e "  ${CYAN}→ Grafana:    http://${GRAFANA_HOST}${NC}"
  echo -e "  ${CYAN}→ MCP docs:   http://${EC2_IP}:8000/docs${NC}"
}


# ── Start ngrok HTTPS tunnel ───────────────────────────────────────────
start_ngrok() {
  hdr "Start ngrok HTTPS Tunnel (for Telegram Webhook)"
  load_env

  # Install ngrok if missing
  if ! command -v ngrok &>/dev/null; then
    echo "  Installing ngrok..."
    curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
    echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | sudo tee /etc/apt/sources.list.d/ngrok.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install -y ngrok
    ok "ngrok installed"
  else
    ok "ngrok: $(ngrok version 2>/dev/null | head -1)"
  fi

  # Auth token
  if [[ -z "$NGROK_AUTH_TOKEN" ]]; then
    echo ""
    warn "ngrok requires a free auth token."
    echo "  Get yours at: https://dashboard.ngrok.com/get-started/your-authtoken"
    echo -n "  Paste your ngrok auth token: "
    read NGROK_AUTH_TOKEN
    [[ -z "$NGROK_AUTH_TOKEN" ]] && { err "Token required — aborting."; return; }
    save_env_var "NGROK_AUTH_TOKEN" "$NGROK_AUTH_TOKEN"
  fi

  ngrok config add-authtoken "$NGROK_AUTH_TOKEN" &>/dev/null

  # Allow changing NGROK_DOMAIN if already set
  if [[ -n "$NGROK_DOMAIN" ]]; then
    echo ""
    echo "  Current domain: $NGROK_DOMAIN"
    echo -n "  Use this domain? [Y/n]: "
    read change_domain
    if [[ "${change_domain,,}" == "n" ]]; then
      echo -n "  New ngrok static domain (or leave blank for random): "
      read new_domain
      if [[ -n "$new_domain" ]]; then
        save_env_var "NGROK_DOMAIN" "$new_domain"
        NGROK_DOMAIN="$new_domain"
        ok "Domain updated: $NGROK_DOMAIN"
        warn "Domain changed → n8n Telegram trigger URL must be updated in n8n UI"
      fi
    fi
  else
    echo -n "  Enter ngrok static domain (leave blank for random URL): "
    read new_domain
    if [[ -n "$new_domain" ]]; then
      save_env_var "NGROK_DOMAIN" "$new_domain"
      NGROK_DOMAIN="$new_domain"
      ok "Domain saved: $NGROK_DOMAIN"
    fi
  fi

  # Kill any existing ngrok
  pkill -f "ngrok http" 2>/dev/null || true
  sleep 1

  # Start tunnel in background
  echo "  Starting ngrok tunnel on port 5678..."
  if [[ -n "$NGROK_DOMAIN" ]]; then
    nohup ngrok http 5678 --domain="$NGROK_DOMAIN" --log=stdout > /tmp/ngrok.log 2>&1 &
    ok "Using static domain: $NGROK_DOMAIN"
  else
    warn "No NGROK_DOMAIN set — URL will change on restart. Get a free static domain at: https://dashboard.ngrok.com/domains"
    nohup ngrok http 5678 --log=stdout > /tmp/ngrok.log 2>&1 &
  fi
  sleep 4

  # Get the HTTPS URL from ngrok local API
  NGROK_URL=$(curl -sf http://localhost:4040/api/tunnels 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
tunnels = data.get('tunnels', [])
for t in tunnels:
    if t.get('proto') == 'https':
        print(t['public_url'])
        break
" 2>/dev/null)

  if [[ -z "$NGROK_URL" ]]; then
    err "Could not get ngrok URL — check /tmp/ngrok.log"
    return
  fi

  ok "ngrok tunnel: $NGROK_URL"
  save_env_var "WEBHOOK_URL" "$NGROK_URL"

  # Restart n8n so it picks up the new WEBHOOK_URL
  echo "  Restarting n8n with new WEBHOOK_URL..."
  cd "$(dirname "$0")"
  docker rm -f n8n
  docker compose up -d n8n
  ok "n8n restarted — Telegram webhooks will use: $NGROK_URL"
  echo ""
  echo -e "  ${CYAN}→ n8n: http://${EC2_PUBLIC_IP}:5678${NC}"
  echo -e "  ${CYAN}→ ngrok dashboard: http://localhost:4040${NC}"
  echo ""
  echo -e "  ${YELLOW}ℹ️  Alertmanager uses EC2 IP directly (not ngrok) — no Prometheus reload needed.${NC}"
  echo -e "  ${YELLOW}   Only re-run option 3 if EC2 IP changed, not if ngrok domain changed.${NC}"
}


# ── Deploy to Kubernetes ───────────────────────────────────────────────────
deploy_to_k8s() {
  hdr "Deploy Dashboard + Target App to Kubernetes"
  load_env

  local all_ok=true

  echo "  Validating endpoints before deployment..."
  echo ""

  # Check Prometheus
  if curl -sf --max-time 5 "${PROMETHEUS_URL}/-/healthy" &>/dev/null; then
    ok "Prometheus:    ${PROMETHEUS_URL}"
  else
    warn "Prometheus:    ${PROMETHEUS_URL} -- UNREACHABLE"
    all_ok=false
  fi

  # Check Grafana
  if curl -sf --max-time 5 "${GRAFANA_URL}/api/health" &>/dev/null; then
    ok "Grafana:       ${GRAFANA_URL}"
  else
    warn "Grafana:       ${GRAFANA_URL} -- UNREACHABLE"
    all_ok=false
  fi

  # Check n8n
  N8N_URL="http://${EC2_PUBLIC_IP}:5678"
  if curl -sf --max-time 5 "${N8N_URL}/healthz" &>/dev/null; then
    ok "n8n:           ${N8N_URL}"
  else
    warn "n8n:           ${N8N_URL} -- UNREACHABLE"
    all_ok=false
  fi

  # Check kubectl
  if kubectl cluster-info &>/dev/null; then
    ok "kubectl:       cluster accessible"
  else
    err "kubectl:       cannot reach cluster -- aborting"
    return
  fi

  echo ""

  if [[ "$all_ok" == "false" ]]; then
    warn "Some endpoints are unreachable."
    echo -n "  Deploy anyway? You will need to configure URLs manually in the dashboard. [y/N]: "
    read ans
    [[ "${ans,,}" != "y" ]] && { echo "  Aborted."; return; }
  fi

  # Ensure namespace
  kubectl get namespace workshop &>/dev/null || kubectl create namespace workshop
  ok "Namespace workshop ready"

  # Inject real URLs into dashboard ConfigMap
  ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://localhost:9093}"
  GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

  sed "
    s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL}|g;
    s|INJECT_GRAFANA_URL|${GRAFANA_URL}|g;
    s|INJECT_ALERTMANAGER_URL|${ALERTMANAGER_URL}|g;
    s|INJECT_N8N_URL|${N8N_URL}|g;
  " ../dashboard/k8s/dashboard.yaml | kubectl apply -f -
  ok "Dashboard deployed"

  # Deploy target-app
  # Inject PUBLIC_URL so browser can reach target-app
  sed "s|PUBLIC_URL.*|PUBLIC_URL\n              value: \"http://${EC2_PUBLIC_IP}:30080\"|g" \
    ../target-app/k8s/deployment.yaml | kubectl apply -f -
  kubectl apply -f ../target-app/k8s/servicemonitor.yaml
  ok "Target-app deployed"

  echo ""
  echo "  Waiting for rollouts..."
  kubectl rollout status deployment/clawops-dashboard -n workshop --timeout=90s
  kubectl rollout status deployment/target-app -n workshop --timeout=90s

  echo ""
  ok "Deployment complete!"
  echo ""
  echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  ${CYAN}  Endpoints:${NC}"
  DASH_HOST=$(kubectl get svc clawops-dashboard -n workshop -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  TARGET_HOST=$(kubectl get svc target-app -n workshop -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [[ -n "$DASH_HOST" ]]; then
    ok "  Dashboard:   http://${DASH_HOST}?prom=${PROMETHEUS_URL}&grafana=${GRAFANA_URL}&am=${ALERTMANAGER_URL}&n8n=http://${EC2_PUBLIC_IP}:5678"
  else
    warn "  Dashboard LB still provisioning — run: kubectl get svc -n workshop"
  fi
  [[ -n "$TARGET_HOST" ]] && ok "  Target App:  http://${TARGET_HOST}:8080"
  echo -e "  ${CYAN}  To add target-app to dashboard: click '+ ADD INSTANCE MANUALLY'${NC}"
  echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}


# ── Clean up Kubernetes workshop namespace ─────────────────────────────────
clean_k8s() {
  hdr "Clean Kubernetes Workshop Resources"
  load_env

  if ! kubectl_works; then
    err "kubectl cannot reach cluster — skipping"
    return
  fi

  echo ""
  warn "This will delete all resources in the workshop namespace:"
  echo "  - clawops-dashboard deployment + service + configmap"
  echo "  - target-app deployment + service + servicemonitor"
  echo "  - workshop namespace"
  echo ""
  echo -n "  Are you sure? [y/N]: "
  read ans
  [[ "${ans,,}" != "y" ]] && { echo "  Aborted."; return; }

  echo ""
  echo "  Removing deployments..."
  kubectl delete deployment clawops-dashboard target-app -n workshop 2>/dev/null && ok "Deployments deleted" || true
  kubectl delete service clawops-dashboard target-app -n workshop 2>/dev/null && ok "Services deleted" || true
  kubectl delete configmap dashboard-config -n workshop 2>/dev/null && ok "ConfigMap deleted" || true
  kubectl delete servicemonitor target-app -n workshop 2>/dev/null && ok "ServiceMonitor deleted" || true

  echo ""
  echo -n "  Also delete the workshop namespace? [y/N]: "
  read ans2
  [[ "${ans2,,}" == "y" ]] && kubectl delete namespace workshop && ok "Namespace deleted" || ok "Namespace kept"
  echo ""
  ok "Cleanup complete. Run option 6 to redeploy."
}

# ── First-run check ───────────────────────────────────────────────────
first_run() {
  local is_new=false
  [ ! -f "$ENV_FILE" ] && cp "$(dirname "$0")/.env.example" "$ENV_FILE" && is_new=true
  load_env

  if [[ "$is_new" == "true" ]]; then
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║   n8n DevOps Workshop — First Run Setup  ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    warn "First-time setup required. Running initial configuration..."
    echo ""
    setup_cluster
    configure_keys
    echo ""
    ok "Initial setup complete. Starting menu..."
    generate_credentials
    sleep 1
  fi
}

# ── Main menu ─────────────────────────────────────────────────────────
menu() {
  while true; do
    load_env
    echo -e "\n${BOLD}${CYAN}  n8n Workshop — Student Console${NC}"
    echo "  ══════════════════════════════"
    echo "  ── Setup (run in order) ──────────────────────"
    echo "  1) Configure cluster       (IP + kubeconfig)"
    echo "  2) Configure API keys      (Gemini, Telegram, TOTP, ngrok)"
    echo "  3) Install Prometheus + Grafana"
    echo "  4) Start stack             (n8n + MCP)  <- needs 1-3"
    echo "  5) Start ngrok tunnel      (Telegram Trigger HTTPS)"
    echo "  6) Deploy Dashboard + Target App to Kubernetes"
    echo "  ── Operations ────────────────────────────────"
    echo "  7) Stop stack"
    echo "  8) Validate full setup"
    echo "  9) Test Telegram bot"
    echo " 10) Show status"
    echo " 11) Generate credentials file"
    echo " 12) Clean Kubernetes workshop resources"
    echo "  q) Quit"
    echo ""
    echo -n "  Choice: "
    read choice
    case $choice in
      1) setup_cluster ;;
      2) configure_keys ;;
      3) start_stack ;;
      4) start_ngrok ;;
      5) install_monitoring ;;
      6) deploy_to_k8s ;;
      7) stop_stack ;;
      8) validate_setup ;;
      9) test_telegram ;;
      10) show_status ;;
      11) generate_credentials ;;
      12) clean_k8s ;;
      q|Q) echo ""; exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

# ── Entry point ───────────────────────────────────────────────────────
first_run
menu
