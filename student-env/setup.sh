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
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
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
  if [[ -z "$WRITE_APPROVAL_TOKEN" ]]; then
    TOKEN=$(openssl rand -hex 32)
    save_env_var "WRITE_APPROVAL_TOKEN" "$TOKEN"
    ok "Write approval token generated: ${TOKEN:0:16}..."
  else
    echo -n "  Write approval token [set, enter to keep or type new]: "
    read val; [[ -n "$val" ]] && { save_env_var "WRITE_APPROVAL_TOKEN" "$val"; ok "Token saved"; } || ok "Kept existing"
  fi

  echo -n "  EC2 public IP (for n8n webhooks) [${EC2_PUBLIC_IP:-not set}]: "
  read val; [[ -n "$val" ]] && { save_env_var "EC2_PUBLIC_IP" "$val"; ok "EC2 IP saved"; }

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
  docker compose up -d --build
  echo ""
  ok "Stack started"
  echo "  n8n:  http://localhost:5678"
  echo "  MCP:  http://localhost:8000/docs"
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

  echo "  Checking Helm..."
  if ! command -v helm &>/dev/null; then
    echo "  Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    ok "Helm installed"
  else
    ok "Helm: $(helm version --short)"
  fi

  echo "  Adding prometheus-community chart repo..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null
  helm repo update &>/dev/null

  echo "  Installing kube-prometheus-stack..."
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f "$(dirname "$0")/../k8s/monitoring/prometheus-values.yaml" \
    --set alertmanager.config.receivers[0].webhook_configs[0].url="http://${EC2_PUBLIC_IP}:5678/webhook/prometheus-alert"

  echo ""
  ok "Monitoring stack installed"
  warn "Update Alertmanager webhook URL if EC2_PUBLIC_IP changed"
  echo ""
  kubectl get pods -n monitoring
}

# ── Validate setup ────────────────────────────────────────────────────
validate_setup() {
  hdr "Validation"
  load_env

  local pass=0 fail=0 warn_count=0

  run_check() {
    local label=$1; shift
    if eval "$@" &>/dev/null; then ok "$label"; ((pass++)); else err "$label"; ((fail++)); fi
  }

  run_warn() {
    local label=$1; shift
    if eval "$@" &>/dev/null; then ok "$label"; ((pass++)); else warn "$label (optional)"; ((warn_count++)); fi
  }

  # ── Core checks (required) ─────────────────────────────
  echo -e "  ${BOLD}Core${NC}"
  run_check "kubectl cluster access"    "kubectl get nodes"
  run_check "Docker daemon"             "docker info"
  run_check "n8n container running"     "docker inspect n8n"
  run_check "MCP container running"     "docker inspect mcp-server"
  run_check "MCP health endpoint"       "curl -sf http://localhost:8000/health"
  run_check "MCP kubectl-read works"    "curl -sf -X POST http://localhost:8000/tools/kubectl-read -H 'Content-Type: application/json' -d '{"command":"get nodes"}'"
  run_check "Gemini API key set"        "[ -n '$GEMINI_API_KEY' ]"
  run_check "Telegram token set"        "[ -n '$TELEGRAM_BOT_TOKEN' ]"
  run_check "Telegram chat ID set"      "[ -n '$TELEGRAM_CHAT_ID' ]"
  run_check "Write approval token set"  "[ -n '$WRITE_APPROVAL_TOKEN' ]"

  # ── Monitoring checks (required for Sessions 5+) ───────
  echo ""
  echo -e "  ${BOLD}Monitoring (needed for Sessions 5-8)${NC}"
  run_warn "Prometheus running"   "kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running 2>/dev/null | grep -q Running"
  run_warn "Grafana running"      "kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --field-selector=status.phase=Running 2>/dev/null | grep -q Running"
  run_warn "Alertmanager running" "kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --field-selector=status.phase=Running 2>/dev/null | grep -q Running"
  run_warn "Prometheus NodePort"  "curl -sf http://${MASTER_IP}:30090/-/healthy"
  run_warn "Grafana NodePort"     "curl -sf http://${MASTER_IP}:30030/api/health"

  # ── Summary ────────────────────────────────────────────
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

# ── First-run check ───────────────────────────────────────────────────
first_run() {
  [ ! -f "$ENV_FILE" ] && cp "$(dirname "$0")/.env.example" "$ENV_FILE"
  load_env

  if ! kubectl_works || [[ -z "$GEMINI_API_KEY" ]]; then
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
    sleep 1
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
  else
    err "Failed to send message."
    echo "  Response: $RESPONSE"
    echo ""
    echo "  Troubleshooting:"
    echo "    1. Verify token: https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/getMe"
    echo "    2. Make sure you sent /start to your bot first"
    echo "    3. Check your chat ID via @userinfobot"
    echo ""
    echo "  Full setup guide: ~/n8nWorkShop/labs/telegram-bot-setup.md"
  fi
}

# ── Main menu ─────────────────────────────────────────────────────────
menu() {
  while true; do
    load_env
    echo -e "\n${BOLD}${CYAN}  n8n Workshop — Student Console${NC}"
    echo "  ══════════════════════════════"
    echo "  1) Show status"
    echo "  2) Re-configure cluster (IP + kubeconfig)"
    echo "  3) Configure API keys (Gemini, Telegram, etc.)"
    echo "  4) Start stack (n8n + MCP)"
    echo "  5) Stop stack"
    echo "  6) Install Prometheus + Grafana"
    echo "  7) Validate full setup"
    echo "  8) Test Telegram bot"
    echo "  q) Quit"
    echo ""
    echo -n "  Choice: "
    read choice
    case $choice in
      1) show_status ;;
      2) setup_cluster ;;
      3) configure_keys ;;
      4) start_stack ;;
      5) stop_stack ;;
      6) install_monitoring ;;
      7) validate_setup ;;
      8) test_telegram ;;
      q|Q) echo ""; exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

# ── Entry point ───────────────────────────────────────────────────────
first_run
menu
