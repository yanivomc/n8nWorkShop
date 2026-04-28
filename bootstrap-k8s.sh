#!/bin/bash
# ── ClawOps Full K8s Bootstrap ────────────────────────────────────────────────
# Deploys everything to K8s with ONE command.
# Installs dependencies, validates, deploys, tests.
# Usage: bash bootstrap-k8s.sh
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSHOP_DIR="$SCRIPT_DIR/k8s/workshop"
CLAWOPS_DIR="$SCRIPT_DIR/k8s/clawops"
INGRESS_DIR="$SCRIPT_DIR/k8s/ingress"
MONITORING_DIR="$SCRIPT_DIR/k8s/monitoring"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
LOG_FILE="/tmp/clawops-bootstrap.log"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✅ $*${NC}"; }
err()  { echo -e "${RED}  ❌ $*${NC}" >&2; }
warn() { echo -e "${YELLOW}  ⚠️  $*${NC}"; }
info() { echo -e "${CYAN}  ℹ️  $*${NC}"; }
hdr()  { echo -e "\n${BOLD}${CYAN}  ══ $* ══${NC}"; }
die()  { err "$*"; echo "  See $LOG_FILE for details"; exit 1; }
run()  { "$@" >> "$LOG_FILE" 2>&1; }

echo "" > "$LOG_FILE"
# ── Menu ─────────────────────────────────────────────────────────────────────
show_menu() {
  echo ""
  echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}  ║       ClawOps Workshop Bootstrap         ║${NC}"
  echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${CYAN}1)${NC} Full bootstrap     (install/upgrade everything)"
  echo -e "  ${CYAN}2)${NC} Update configs     (refresh configmaps + restart pods)"
  echo -e "  ${CYAN}3)${NC} Update ingress     (re-apply ingress rules)"
  echo -e "  ${CYAN}4)${NC} Import workflows   (push S2/S4/S5/S6/S8 to n8n)"
  echo -e "  ${CYAN}5)${NC} Show TOTP / QR code  (instructor — scan with Authy)"
  echo -e "  ${CYAN}6)${NC} Reset incidents    (clear all MCP incidents)"
  echo -e "  ${CYAN}7)${NC} Validate           (run health checks)"
  echo -e "  ${RED}8)${NC} Delete ALL         (wipe everything — fresh start)"
  echo -e "  ${CYAN}q)${NC} Quit"
  echo ""
  echo -n "  Choice [1]: "
  read CHOICE
  CHOICE=${CHOICE:-1}
}

delete_all() {
  hdr "Delete ALL Workshop Resources"
  echo -e "${RED}  ⚠️  This will delete ALL workshop namespaces and monitoring!${NC}"
  echo -n "  Type 'yes' to confirm: "
  read confirm
  [[ "$confirm" != "yes" ]] && { warn "Aborted."; return; }

  info "Deleting ingresses..."
  kubectl delete ingress --all -n clawops 2>/dev/null || true
  kubectl delete ingress --all -n workshop 2>/dev/null || true
  kubectl delete ingress --all -n monitoring 2>/dev/null || true

  info "Deleting clawops namespace (n8n, mcp, dashboard)..."
  kubectl delete namespace clawops 2>/dev/null || true

  info "Deleting workshop namespace (target-app)..."
  kubectl delete namespace workshop 2>/dev/null || true

  info "Deleting monitoring stack..."
  helm uninstall monitoring -n monitoring 2>/dev/null || true
  kubectl delete namespace monitoring 2>/dev/null || true

  info "Deleting ingress-nginx..."
  helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
  kubectl delete namespace ingress-nginx 2>/dev/null || true

  ok "All resources deleted. Run option 1 for fresh bootstrap."
}

update_configs() {
  hdr "Update Configs + Restart Pods"
  load_ingress_lb
  load_monitoring_urls
  detect_master_ip
  apply_configmaps
  apply_workshop_configmaps
  restart_pods
  ok "Done"
}

load_ingress_lb() {
  INGRESS_LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [[ -z "$INGRESS_LB" ]] && INGRESS_LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx     -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ -z "$INGRESS_LB" ]] && warn "Ingress LB not found — continuing without LB URL"
  ok "Ingress LB: $INGRESS_LB"
}

load_monitoring_urls() {
  PROMETHEUS_URL="http://$(kubectl get svc monitoring-kube-prometheus-prometheus -n monitoring     -o jsonpath='{.spec.clusterIP}' 2>/dev/null):9090"
  GRAFANA_URL="http://$(kubectl get svc monitoring-grafana -n monitoring     -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  ALERTMANAGER_URL="http://$(kubectl get svc monitoring-kube-prometheus-alertmanager -n monitoring     -o jsonpath='{.spec.clusterIP}' 2>/dev/null):9093"
}

detect_master_ip() {
  if [[ -z "$MASTER_IP" ]]; then
    MASTER_IP=$(curl -sf --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
  fi
  if [[ -z "$MASTER_IP" ]]; then
    MASTER_IP=$(curl -sf --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n')
  fi
  [[ -n "$MASTER_IP" ]] && ok "Master IP: $MASTER_IP" || warn "Could not detect MASTER_IP"
}

apply_configmaps() {
  info "Applying configmaps with fresh values..."
  # Internal Prometheus ClusterIP for n8n + mcp (backend access)
  PROM_INTERNAL=$(kubectl get svc monitoring-kube-prometheus-prometheus -n monitoring \
    -o jsonpath='http://{.spec.clusterIP}:9090' 2>/dev/null || echo "http://prometheus-pending")

  sed "s|INJECT_N8N_HOST|${INGRESS_LB}|g; \
       s|INJECT_N8N_PASSWORD|changeme123|g; \
       s|INJECT_PROMETHEUS_URL|${PROM_INTERNAL}|g" \
    "$CLAWOPS_DIR/n8n/configmap.yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1

  sed "s|INJECT_PROMETHEUS_URL|${PROM_INTERNAL}|g" \
    "$CLAWOPS_DIR/mcp-server/configmap.yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1

  # Dashboard uses INGRESS paths — never ClusterIP
  sed "s|INJECT_PROMETHEUS_URL|http://${INGRESS_LB}/prometheus|g; \
       s|INJECT_GRAFANA_URL|http://${INGRESS_LB}/grafana|g; \
       s|INJECT_ALERTMANAGER_URL|http://${INGRESS_LB}/alertmanager/|g; \
       s|INJECT_INGRESS_LB|${INGRESS_LB}|g; \
       s|INJECT_MASTER_IP|${MASTER_IP}|g" \
    "$CLAWOPS_DIR/dashboard/configmap.yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1
  ok "Configmaps applied (dashboard uses ingress paths)"
}

restart_pods() {
  info "Restarting pods..."
  kubectl rollout restart deployment/n8n -n clawops >> "$LOG_FILE" 2>&1 || true
  kubectl rollout restart deployment/mcp-server -n clawops >> "$LOG_FILE" 2>&1 || true
  kubectl rollout restart deployment/clawops-dashboard -n clawops >> "$LOG_FILE" 2>&1 || true
  kubectl rollout restart deployment/event-watcher -n clawops >> "$LOG_FILE" 2>&1 || true
  kubectl rollout restart deployment/linux-mcp-server -n clawops >> "$LOG_FILE" 2>&1 || true
  sleep 30
  ok "Pods restarted"
}

apply_workshop_configmaps() {
  info "Applying workshop configmaps + deployments..."
  # Ensure namespaces exist first
  kubectl apply -f "$CLAWOPS_DIR/namespace.yaml" >> "$LOG_FILE" 2>&1 || true
  kubectl apply -f "$WORKSHOP_DIR/namespace.yaml" >> "$LOG_FILE" 2>&1 || true
  # Re-apply all clawops deployments + services
  kubectl apply -f "$K8S_DIR/clawops/event-watcher/deployment.yaml" >> "$LOG_FILE" 2>&1 || true
  kubectl apply -f "$K8S_DIR/clawops/event-watcher/service.yaml" >> "$LOG_FILE" 2>&1 || true
  kubectl apply -f "$K8S_DIR/clawops/linux-mcp-server/deployment.yaml" >> "$LOG_FILE" 2>&1 || true
  kubectl apply -f "$K8S_DIR/clawops/linux-mcp-server/service.yaml" >> "$LOG_FILE" 2>&1 || true
  kubectl apply -f "$K8S_DIR/clawops/dashboard/deployment.yaml" >> "$LOG_FILE" 2>&1 || true
  kubectl apply -f "$K8S_DIR/clawops/dashboard/service.yaml" >> "$LOG_FILE" 2>&1 || true
  # Restart to pick up configmap changes
  kubectl rollout restart deployment/event-watcher -n clawops >> "$LOG_FILE" 2>&1 || true
  kubectl rollout restart deployment/clawops-dashboard -n clawops >> "$LOG_FILE" 2>&1 || true
  # Workshop
  kubectl apply -f "$WORKSHOP_DIR/target-app/deployment.yaml" >> "$LOG_FILE" 2>&1 || true
  kubectl rollout restart deployment/target-app -n workshop >> "$LOG_FILE" 2>&1 || true
  info "Checking event-watcher deployment..."
  kubectl get deployment event-watcher -n clawops 2>&1 | head -3
  ok "All deployments + configmaps applied"
}


reset_incidents() {
  hdr "Reset Incidents"
  MCP_IP=$(kubectl get svc mcp-server -n clawops -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  if [[ -z "$MCP_IP" ]]; then
    die "mcp-server not found — is the cluster running?"
  fi
  echo ""
  warn "This will DELETE all incidents from the MCP store."
  read -rp "  Type 'yes' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    info "Cancelled."; return
  fi
  RESULT=$(curl -sf -X DELETE "http://${MCP_IP}:8000/incidents" 2>/dev/null)
  ok "Incidents cleared: $RESULT"
}

show_totp() {
  hdr "TOTP Secret"
  TOTP_SECRET=$(kubectl get secret mcp-secrets -n clawops \
    -o jsonpath='{.data.TOTP_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  if [[ -z "$TOTP_SECRET" ]]; then
    info "No secret found — generating new one..."
    TOTP_SECRET=$(python3 -c "import pyotp; print(pyotp.random_base32())" 2>/dev/null || \
                  openssl rand -base64 20 | tr -d '+=/' | cut -c1-32 | tr '[:lower:]' '[:upper:]')
    WRITE_TOKEN=$(openssl rand -hex 32)
    kubectl create namespace clawops 2>/dev/null || true
    kubectl create secret generic mcp-secrets \
      --from-literal=TOTP_SECRET="$TOTP_SECRET" \
      --from-literal=WRITE_APPROVAL_TOKEN="$WRITE_TOKEN" \
      -n clawops --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
    kubectl rollout restart deployment/mcp-server -n clawops >> "$LOG_FILE" 2>&1 || true
    ok "Generated and saved new TOTP secret (mcp-server restarted)"
  fi
  echo ""
  echo -e "  ${BOLD}TOTP_SECRET=${TOTP_SECRET}${NC}"
  echo -e "  📱  QR: https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=otpauth%3A%2F%2Ftotp%2FClawOps%2520Workshop%3Fsecret%3D${TOTP_SECRET}%26issuer%3Dn8nWorkshop"
  echo ""
  ok "Open QR in browser → scan with Authy / Google Authenticator"
}

update_ingress() {
  hdr "Update Ingress Rules"
  kubectl delete ingress --all -n clawops 2>/dev/null || true
  kubectl delete ingress --all -n monitoring 2>/dev/null || true
  kubectl apply -f "$INGRESS_DIR/ingress.yaml" >> "$LOG_FILE" 2>&1
  ok "Ingress applied"
}

import_workflows() {
  hdr "Import n8n Workflows"
  load_ingress_lb
  N8N_IP=$(kubectl get svc n8n -n clawops -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  N8N_URL="http://${N8N_IP}:5678"

  # Try saved key first
  SAVED_KEY=$(kubectl get configmap n8n-config -n clawops     -o jsonpath='{.data.N8N_API_KEY}' 2>/dev/null || echo "")

  if [[ -n "$SAVED_KEY" ]]; then
    echo -e "  Found saved API key: ${SAVED_KEY:0:20}..."
    echo -n "  Use it? [Y/n]: "
    read use_saved
    [[ "${use_saved,,}" == "n" ]] && SAVED_KEY=""
  fi

  if [[ -z "$SAVED_KEY" ]]; then
    echo ""
    echo -e "  ${CYAN}No API key found. Generate one in n8n:${NC}"
    echo -e "  1. Open http://${INGRESS_LB}/"
    echo -e "  2. Go to Settings → API → Create API Key"
    echo -e "  3. Copy and paste it here"
    echo ""
    echo -n "  Paste your n8n API key: "
    read -r SAVED_KEY
    [[ -z "$SAVED_KEY" ]] && { warn "No key provided — skipping"; return; }
    # Save it to configmap for next time
    kubectl patch configmap n8n-config -n clawops       --type merge -p "{"data":{"N8N_API_KEY":"${SAVED_KEY}"}}" >> "$LOG_FILE" 2>&1 &&       ok "API key saved to configmap for future runs"
  fi

  N8N_KEY="$SAVED_KEY"
  for wf in s2-ai-agent-mcp s2.5-linux-agent s4-telegram-human-loop s5-alert-intelligence s6-k8s-event-intelligence s8-k8s-event-jwt; do
    python3 -c "
import json
with open('n8n-workflows/${wf}.json') as f: d=json.load(f)
d['settings']={'executionOrder':'v1','saveManualExecutions':True,'saveDataErrorExecution':'all','saveDataSuccessExecution':'all'}
d.pop('id', None)
d.pop('versionId', None)
with open('/tmp/${wf}.json','w') as f: json.dump(d,f)" 2>/dev/null
    result=$(curl -sf -X POST "${N8N_URL}/api/v1/workflows"       -H "X-N8N-API-KEY: ${N8N_KEY}" -H "Content-Type: application/json"       -d @/tmp/${wf}.json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','ERR'))" 2>/dev/null)
    [[ -n "$result" && "$result" != "ERR" ]] && ok "Imported $wf (id: $result)" || warn "Failed: $wf"
  done
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Allow non-interactive: ./bootstrap-k8s.sh run
if [[ "${1}" == "run" ]]; then
  CHOICE=1
else
  show_menu
fi
case $CHOICE in
  1) : ;; # fall through to full bootstrap below
  2) update_configs; exit 0 ;;
  3) load_ingress_lb; update_ingress; exit 0 ;;
  4) import_workflows; exit 0 ;;
  5) show_totp; exit 0 ;;
  6) reset_incidents; exit 0 ;;
  7) load_ingress_lb
     N8N_IP=$(kubectl get svc n8n -n clawops -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
     MCP_IP=$(kubectl get svc mcp-server -n clawops -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
     PASS=0; FAIL=0
     check() { local label="$1"; shift; if eval "$@" >> "$LOG_FILE" 2>&1; then ok "$label"; ((PASS++)); else warn "FAIL: $label"; ((FAIL++)); fi }
     check "n8n pod running" "kubectl get pods -n clawops -l app=n8n --field-selector=status.phase=Running | grep -q n8n"
     check "mcp-server pod running" "kubectl get pods -n clawops -l app=mcp-server --field-selector=status.phase=Running | grep -q mcp"
     check "dashboard pod running" "kubectl get pods -n clawops -l app=clawops-dashboard --field-selector=status.phase=Running | grep -q clawops"
     check "target-app pod running" "kubectl get pods -n workshop -l app=target-app --field-selector=status.phase=Running | grep -q target"
     [[ -n "$N8N_IP" ]] && check "n8n healthz" "curl -sf --max-time 5 http://${N8N_IP}:5678/healthz -o /dev/null"
     [[ -n "$MCP_IP" ]] && check "mcp-server health" "curl -sf --max-time 5 http://${MCP_IP}:8000/health -o /dev/null"
LINUX_MCP_IP=$(kubectl get svc linux-mcp-server -n clawops -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
EW_IP=$(kubectl get svc event-watcher -n clawops -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
CL_IP=$(kubectl get svc target-app -n workshop -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[[ -n "$CL_IP" ]] && check "chaos-loader sidecar health" "curl -sf --max-time 5 http://${CL_IP}:8003/health -o /dev/null"
[[ -n "$EW_IP" ]] && check "event-watcher health" "curl -sf --max-time 5 http://${EW_IP}:8002/health -o /dev/null"
[[ -n "$LINUX_MCP_IP" ]] && check "linux-mcp-server health" "curl -sf --max-time 5 http://${LINUX_MCP_IP}:8001/health -o /dev/null"
     check "ingress LB reachable" "curl -sf --max-time 10 http://${INGRESS_LB}/ -o /dev/null"
     check "dashboard accessible" "curl -sfL --max-time 10 http://${INGRESS_LB}/dashboard/ | grep -qi clawops"
     echo -e "\n  Tests: ${GREEN}${PASS} passed${NC}  ${FAIL} failed"
     exit 0 ;;
  8) delete_all; exit 0 ;;
  q|Q) exit 0 ;;
  *) warn "Invalid — running full bootstrap" ;;
esac


# ── PHASE 0: Install dependencies ────────────────────────────────────────────
hdr "Phase 0 — Dependencies"

# kubectl
if ! command -v kubectl &>/dev/null; then
  info "Installing kubectl..."
  curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    >> "$LOG_FILE" 2>&1
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/
  ok "kubectl installed"
else
  ok "kubectl: $(kubectl version --client --short 2>/dev/null | head -1)"
fi

# helm
if ! command -v helm &>/dev/null; then
  info "Installing helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
    >> "$LOG_FILE" 2>&1 || die "Failed to install helm"
  ok "helm installed"
else
  ok "helm: $(helm version --short 2>/dev/null)"
fi

# python3 + pyotp (for TOTP generation) — install system-wide
if ! python3 -c "import pyotp" 2>/dev/null; then
  info "Installing pyotp..."
  pip3 install pyotp --break-system-packages --quiet >> "$LOG_FILE" 2>&1 || \
  pip3 install pyotp --quiet >> "$LOG_FILE" 2>&1 || \
  sudo pip3 install pyotp --break-system-packages --quiet >> "$LOG_FILE" 2>&1 || true
  python3 -c "import pyotp" 2>/dev/null && ok "pyotp installed" || warn "pyotp install failed — using openssl fallback"
else
  ok "pyotp already available"
fi

# ── PHASE 1: Validate cluster access ─────────────────────────────────────────
hdr "Phase 1 — Cluster validation"

kubectl cluster-info >> "$LOG_FILE" 2>&1 || die "Cannot reach K8s cluster — check kubeconfig"
ok "Cluster reachable"

kubectl get nodes >> "$LOG_FILE" 2>&1 || die "Cannot list nodes"
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
ok "$NODE_COUNT node(s) found"

[[ -f "$KUBECONFIG_PATH" ]] || die "kubeconfig not found at $KUBECONFIG_PATH"
ok "kubeconfig: $KUBECONFIG_PATH"

# ── PHASE 2: Install ingress-nginx ───────────────────────────────────────────
hdr "Phase 2 — ingress-nginx"

info "Adding helm repos..."
run helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
run helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
run helm repo update
ok "Helm repos updated"

# Fix stuck release before install
INGRESS_STATUS=$(helm status ingress-nginx -n ingress-nginx 2>/dev/null | grep "STATUS:" | awk '{print $2}')
if [[ "$INGRESS_STATUS" == "failed" || "$INGRESS_STATUS" == "pending-install" || "$INGRESS_STATUS" == "pending-upgrade" ]]; then
  warn "ingress-nginx stuck in '$INGRESS_STATUS' — uninstalling first..."
  helm uninstall ingress-nginx -n ingress-nginx >> "$LOG_FILE" 2>&1 || true
  sleep 5
fi

if helm status ingress-nginx -n ingress-nginx 2>/dev/null | grep -q "deployed"; then
  ok "ingress-nginx already installed"
else
  info "Installing ingress-nginx (60-90s)..."
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx --create-namespace \
    -f "$INGRESS_DIR/ingress-nginx-values.yaml" \
    --wait --timeout 5m >> "$LOG_FILE" 2>&1 || die "ingress-nginx install failed"
  ok "ingress-nginx installed"
fi

# ── PHASE 3: Wait for ingress LB ─────────────────────────────────────────────
hdr "Phase 3 — Ingress LoadBalancer"

info "Waiting for LB address (up to 2 min)..."
INGRESS_LB=""
for i in $(seq 1 24); do
  INGRESS_LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [[ -z "$INGRESS_LB" ]] && INGRESS_LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ -n "$INGRESS_LB" ]] && break
  echo -n "  ." ; sleep 5
done
echo ""
[[ -z "$INGRESS_LB" ]] && die "Ingress LB has no address yet — try again in 1 min"
ok "Ingress LB: $INGRESS_LB"

# ── PHASE 4: Install Prometheus + Grafana ────────────────────────────────────
hdr "Phase 4 — Monitoring stack"

if helm status monitoring -n monitoring 2>/dev/null | grep -q "deployed"; then
  info "Monitoring already installed — upgrading to apply latest config (Alertmanager URL)..."
fi
if true; then  # always upgrade
  info "Installing kube-prometheus-stack (2-3 min)..."
  # Alertmanager → n8n via internal K8s DNS — never needs IP update!
  sed "s|EC2_PUBLIC_IP_PLACEHOLDER|n8n.clawops.svc.cluster.local|g" \
    "$MONITORING_DIR/prometheus-values.yaml" > /tmp/prom-values.yaml

  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f /tmp/prom-values.yaml \
    --wait --timeout 5m >> "$LOG_FILE" 2>&1 || die "Monitoring install/upgrade failed"
  ok "Monitoring installed"
fi

# Fetch LB hostnames
PROMETHEUS_URL=$(kubectl get svc monitoring-kube-prometheus-prometheus -n monitoring \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}:9090' 2>/dev/null)
GRAFANA_URL=$(kubectl get svc monitoring-grafana -n monitoring \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
ALERTMANAGER_URL=$(kubectl get svc monitoring-kube-prometheus-alertmanager -n monitoring \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}:9093' 2>/dev/null)
ok "Prometheus: via ingress http://${INGRESS_LB}/prometheus"
ok "Grafana: via ingress http://${INGRESS_LB}/grafana"
ok "Alertmanager: via ingress http://${INGRESS_LB}/alertmanager"

# ── PHASE 4.5: Build & push MCP server image ─────────────────────────────────
hdr "Phase 4.5 — MCP + Linux MCP images"

MCP_IMAGE="yanivomc/mcp-server:latest"

# Check if image exists on Docker Hub
if docker manifest inspect "$MCP_IMAGE" >> "$LOG_FILE" 2>&1; then
  ok "MCP image already on Docker Hub"
else
  info "Building MCP server image (first time — takes ~2 min)..."
  if ! command -v docker &>/dev/null; then
    warn "Docker not found — skipping image build. Make sure $MCP_IMAGE exists on Docker Hub."
  else
    cd "$SCRIPT_DIR/mcp-server"
    docker build -t "$MCP_IMAGE" . >> "$LOG_FILE" 2>&1 || die "MCP image build failed"
    info "Pushing MCP image to Docker Hub..."
    docker push "$MCP_IMAGE" >> "$LOG_FILE" 2>&1 || die "MCP image push failed — are you logged in? Run: docker login"
    ok "MCP image built and pushed"
    cd "$SCRIPT_DIR"
  fi
fi

# ── PHASE 5: Deploy workshop services ────────────────────────────────────────
# ── Detect master node public IP ─────────────────────────────────────────────
if [[ -z "$MASTER_IP" ]]; then
  MASTER_IP=$(curl -sf --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
fi
if [[ -z "$MASTER_IP" ]]; then
  MASTER_IP=$(curl -sf --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n')
fi
if [[ -n "$MASTER_IP" ]]; then
  ok "Master IP: $MASTER_IP"
else
  warn "Could not auto-detect MASTER_IP — Terminal/VSCode tabs will not work"
  warn "Set it manually: export MASTER_IP=<your-ec2-public-ip> && bash bootstrap-k8s.sh"
fi

hdr "Phase 5 — Workshop services"

# Namespace
kubectl apply -f "$WORKSHOP_DIR/namespace.yaml"
kubectl apply -f "$CLAWOPS_DIR/namespace.yaml" >> "$LOG_FILE" 2>&1
ok "Namespaces: workshop + clawops"

# MCP RBAC — ServiceAccount with in-cluster auth
kubectl apply -f "$CLAWOPS_DIR/mcp-server/rbac.yaml" >> "$LOG_FILE" 2>&1
ok "MCP RBAC (ServiceAccount)"

# kubeconfig secret for MCP
kubectl create secret generic workshop-kubeconfig \
  --from-file=config="$KUBECONFIG_PATH" \
  -n clawops --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
ok "kubeconfig secret (clawops)"

# TOTP + write token — auto-generated, no student input needed
# Reuse existing TOTP if cluster already has one — new cluster = new key
TOTP_SECRET=$(kubectl get secret mcp-secrets -n clawops   -o jsonpath='{.data.TOTP_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [[ -z "$TOTP_SECRET" ]]; then
  TOTP_SECRET=$(kubectl exec -n clawops deployment/mcp-server -- \
    python3 -c "import pyotp; print(pyotp.random_base32())" 2>/dev/null || \
    python3 -c "import pyotp; print(pyotp.random_base32())" 2>/dev/null || \
    openssl rand -base64 32 | tr -dc 'A-Z2-7' | head -c 32)
  info "Generated new TOTP secret"
else
  ok "Reusing existing TOTP secret from cluster"
fi
WRITE_TOKEN=$(kubectl get secret mcp-secrets -n clawops   -o jsonpath='{.data.WRITE_APPROVAL_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null ||   openssl rand -hex 32)

kubectl create secret generic mcp-secrets \
  --from-literal=TOTP_SECRET="$TOTP_SECRET" \
  --from-literal=WRITE_APPROVAL_TOKEN="$WRITE_TOKEN" \
  -n clawops --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
ok "MCP secrets (TOTP auto-generated)"

# Apply PVCs first (needed before deployments)
kubectl apply -f "$CLAWOPS_DIR/n8n/pvc.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$CLAWOPS_DIR/mcp-server/pvc.yaml" >> "$LOG_FILE" 2>&1
ok "PVCs created"

# n8n
sed "s|INJECT_N8N_HOST|$INGRESS_LB|g; \
     s|INJECT_N8N_PASSWORD|changeme123|g; \
     s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL:-http://prometheus-pending}|g" \
  "$CLAWOPS_DIR/n8n/configmap.yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1
kubectl apply -f "$CLAWOPS_DIR/n8n/pvc.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$CLAWOPS_DIR/n8n/deployment.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$CLAWOPS_DIR/n8n/service.yaml" >> "$LOG_FILE" 2>&1
ok "n8n"

# MCP server
sed "s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL:-http://prometheus-pending}|g" \
  "$CLAWOPS_DIR/mcp-server/configmap.yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1
kubectl apply -f "$CLAWOPS_DIR/mcp-server/pvc.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$CLAWOPS_DIR/mcp-server/deployment.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$CLAWOPS_DIR/mcp-server/service.yaml" >> "$LOG_FILE" 2>&1
ok "MCP server"

# Dashboard
sed "s|INJECT_PROMETHEUS_URL|http://${INGRESS_LB}/prometheus|g; \
     s|INJECT_GRAFANA_URL|http://${INGRESS_LB}/grafana|g; \
     s|INJECT_ALERTMANAGER_URL|http://${INGRESS_LB}/alertmanager/|g; \
     s|INJECT_INGRESS_LB|${INGRESS_LB}|g; \
     s|INJECT_MASTER_IP|${MASTER_IP}|g" \
  "$CLAWOPS_DIR/dashboard/configmap.yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1
kubectl apply -f "$CLAWOPS_DIR/dashboard/deployment.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$CLAWOPS_DIR/dashboard/service.yaml" >> "$LOG_FILE" 2>&1
ok "Dashboard"

# Restart all clawops deployments to pick up any configmap changes
info "Restarting deployments to apply latest configmaps..."
kubectl rollout restart deployment/n8n -n clawops >> "$LOG_FILE" 2>&1 || true
kubectl rollout restart deployment/mcp-server -n clawops >> "$LOG_FILE" 2>&1 || true
kubectl rollout restart deployment/clawops-dashboard -n clawops >> "$LOG_FILE" 2>&1 || true
ok "Deployments restarted (configmaps refreshed)"
info "Waiting 30s for pods to restart..."
sleep 30

# Linux MCP server
kubectl apply -f "$K8S_DIR/clawops/linux-mcp-server/deployment.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$K8S_DIR/clawops/linux-mcp-server/service.yaml" >> "$LOG_FILE" 2>&1

# Event watcher
kubectl apply -f "$K8S_DIR/clawops/event-watcher/deployment.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$K8S_DIR/clawops/event-watcher/service.yaml" >> "$LOG_FILE" 2>&1
ok "event-watcher" >> "$LOG_FILE" 2>&1
ok "linux-mcp-server"

# Target app
kubectl apply -f "$WORKSHOP_DIR/target-app/deployment.yaml" >> "$LOG_FILE" 2>&1
ok "target-app"

# ── PHASE 6: Ingress rules ────────────────────────────────────────────────────
hdr "Phase 6 — Ingress rules"
# Delete old single ingress if exists (avoid duplicate path conflicts)
kubectl delete ingress workshop-ingress -n workshop 2>/dev/null || true
kubectl delete ingress workshop-ingress -n clawops 2>/dev/null || true
kubectl apply -f "$INGRESS_DIR/ingress.yaml" >> "$LOG_FILE" 2>&1
ok "Ingress rules applied"

# ── PHASE 7: Wait for pods ────────────────────────────────────────────────────
hdr "Phase 7 — Waiting for pods"
info "Waiting for n8n (up to 2 min)..."
kubectl rollout status deployment/n8n -n clawops --timeout=120s >> "$LOG_FILE" 2>&1 \
  && ok "n8n ready" || warn "n8n not ready yet — check: kubectl get pods -n workshop"
kubectl rollout status deployment/mcp-server -n clawops --timeout=120s >> "$LOG_FILE" 2>&1 \
  && ok "mcp-server ready" || warn "mcp-server not ready yet"
kubectl rollout status deployment/clawops-dashboard -n clawops --timeout=60s >> "$LOG_FILE" 2>&1 \
  && ok "dashboard ready" || warn "dashboard not ready yet"
kubectl rollout status deployment/event-watcher -n clawops --timeout=60s >> "$LOG_FILE" 2>&1 \
  && ok "event-watcher ready" || warn "event-watcher not ready"
kubectl rollout status deployment/linux-mcp-server -n clawops --timeout=60s >> "$LOG_FILE" 2>&1 \
  && ok "linux-mcp-server ready" || warn "linux-mcp-server not ready"
kubectl rollout status deployment/target-app -n workshop --timeout=60s >> "$LOG_FILE" 2>&1 \
  && ok "target-app ready" || warn "target-app not ready yet"

# ── PHASE 8: Tests ────────────────────────────────────────────────────────────
hdr "Phase 8 — Validation tests"

PASS=0; FAIL=0
check() {
  local label="$1"; local cmd="${@:2}"
  if eval "$cmd" >> "$LOG_FILE" 2>&1; then
    ok "$label"
    ((PASS++))
  else
    warn "FAIL: $label"
    ((FAIL++))
  fi
}

# Pod checks
check "n8n pod running" \
  "kubectl get pods -n clawops -l app=n8n --field-selector=status.phase=Running | grep -q n8n"
check "mcp-server pod running" \
  "kubectl get pods -n clawops -l app=mcp-server --field-selector=status.phase=Running | grep -q mcp"
check "dashboard pod running" \
  "kubectl get pods -n clawops -l app=clawops-dashboard --field-selector=status.phase=Running | grep -q clawops"
check "target-app pod running" \
  "kubectl get pods -n workshop -l app=target-app --field-selector=status.phase=Running | grep -q target"

# Internal connectivity (from within cluster via kubectl exec)
N8N_POD=$(kubectl get pods -n clawops -l app=n8n -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
MCP_POD=$(kubectl get pods -n clawops -l app=mcp-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -n "$N8N_POD" ]]; then
  check "n8n healthz endpoint" \
    "kubectl exec -n workshop $N8N_POD -- wget -qO- http://localhost:5678/healthz"
fi
if [[ -n "$MCP_POD" ]]; then
  check "mcp-server health endpoint" \
    "kubectl exec -n workshop $MCP_POD -- wget -qO- http://localhost:8000/health"
fi

# Ingress LB reachable (may need DNS propagation)
check "ingress LB reachable" \
  "curl -sf --max-time 10 http://${INGRESS_LB}/ -o /dev/null"

# Ingress routing
check "ingress routes to dashboard" \
  "curl -sfL --max-time 10 http://${INGRESS_LB}/dashboard/ | grep -qi clawops"
check "ingress routes to n8n" \
  "curl -sf --max-time 10 -L http://${INGRESS_LB}/n8n/ -o /dev/null"

echo ""
echo -e "  Tests: ${GREEN}${PASS} passed${NC}  ${FAIL} failed"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}  ════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅  Bootstrap complete!${NC}"
echo -e "${BOLD}${GREEN}  ════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}  All services via ONE LB:${NC}"
echo -e "  📊  Dashboard:    http://${INGRESS_LB}/dashboard"
echo -e "  🤖  n8n:          http://${INGRESS_LB}/n8n"
echo -e "  🔧  MCP Docs:     http://${INGRESS_LB}/mcp/docs"
echo -e "  📈  Prometheus:   http://${INGRESS_LB}/prometheus"
echo -e "  📊  Grafana:      http://${INGRESS_LB}/grafana  (admin/workshop123)"
echo -e "  🔔  Alertmanager: ${ALERTMANAGER_URL:-pending}"
echo ""
echo -e "${YELLOW}  📋  INSTRUCTOR — TOTP secret (add to Authy for live demos):${NC}"
echo -e "  TOTP_SECRET=${TOTP_SECRET}"
echo -e "  📱  QR: https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=otpauth%3A%2F%2Ftotp%2FClawOps%2520Workshop%3Fsecret%3D${TOTP_SECRET}%26issuer%3Dn8nWorkshop"
echo ""
echo -e "${CYAN}  Student setup (2 min):${NC}"
echo -e "  1. Open http://${INGRESS_LB}/n8n → Credentials → add Gemini API key"
echo -e "  2. Import workflows from /n8n-workflows/"

# ── Auto-import n8n workflows ─────────────────────────────────────────────────
hdr "Bonus — Auto-import n8n workflows"
N8N_URL="http://localhost:5678"
# Wait for n8n to be reachable via port-forward or ClusterIP
N8N_IP=$(kubectl get svc n8n -n clawops -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [[ -n "$N8N_IP" ]]; then
  N8N_URL="http://${N8N_IP}:5678"
fi
N8N_KEY=$(kubectl get configmap n8n-config -n clawops   -o jsonpath='{.data.N8N_API_KEY}' 2>/dev/null || echo "")
if [[ -z "$N8N_KEY" ]]; then
  warn "N8N_API_KEY not in ConfigMap — skip workflow import. Set key in n8n UI then re-run: bash student-env/setup.sh"
else
  for wf in s2-ai-agent-mcp s2.5-linux-agent s4-telegram-human-loop s5-alert-intelligence s6-k8s-event-intelligence s8-k8s-event-jwt; do
    python3 -c "
import json
with open('n8n-workflows/${wf}.json') as f: d=json.load(f)
d['settings']={'executionOrder':'v1','saveManualExecutions':True,'saveDataErrorExecution':'all','saveDataSuccessExecution':'all'}
d.pop('id', None)
d.pop('versionId', None)
with open('/tmp/${wf}.json','w') as f: json.dump(d,f)" 2>/dev/null
    result=$(curl -sf -X POST "${N8N_URL}/api/v1/workflows"       -H "X-N8N-API-KEY: ${N8N_KEY}" -H "Content-Type: application/json"       -d @/tmp/${wf}.json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','ERR'))" 2>/dev/null)
    [[ "$result" != "ERR" ]] && ok "Imported: $wf (id: $result)" || warn "Could not import $wf"
  done
fi
echo -e "  3. Open http://${INGRESS_LB}/ → ready ✅"
echo ""
warn "DNS propagation for LB hostname can take 1-2 min — if URLs don't load yet, wait and retry"
echo ""
echo -e "  Full log: $LOG_FILE"
