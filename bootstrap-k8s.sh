#!/bin/bash
# ── ClawOps Full K8s Bootstrap ────────────────────────────────────────────────
# Deploys everything to K8s with ONE command.
# Installs dependencies, validates, deploys, tests.
# Usage: bash bootstrap-k8s.sh
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSHOP_DIR="$SCRIPT_DIR/k8s/workshop"
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

# python3 + pyotp (for TOTP generation)
if ! python3 -c "import pyotp" 2>/dev/null; then
  info "Installing pyotp..."
  pip3 install pyotp --break-system-packages --quiet >> "$LOG_FILE" 2>&1 || \
  pip3 install pyotp --quiet >> "$LOG_FILE" 2>&1 || true
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
  ok "Monitoring already installed"
else
  info "Installing kube-prometheus-stack (2-3 min)..."
  # Alertmanager → n8n via internal K8s DNS — never needs IP update!
  sed "s|EC2_PUBLIC_IP_PLACEHOLDER|n8n.workshop.svc.cluster.local|g" \
    "$MONITORING_DIR/prometheus-values.yaml" > /tmp/prom-values.yaml

  helm install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f /tmp/prom-values.yaml \
    --wait --timeout 5m >> "$LOG_FILE" 2>&1 || die "Monitoring install failed"
  ok "Monitoring installed"
fi

# Fetch LB hostnames
PROMETHEUS_URL=$(kubectl get svc monitoring-kube-prometheus-prometheus -n monitoring \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}:9090' 2>/dev/null)
GRAFANA_URL=$(kubectl get svc monitoring-grafana -n monitoring \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
ALERTMANAGER_URL=$(kubectl get svc monitoring-kube-prometheus-alertmanager -n monitoring \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}:9093' 2>/dev/null)
ok "Prometheus:   ${PROMETHEUS_URL:-pending}"
ok "Grafana:      ${GRAFANA_URL:-pending}"
ok "Alertmanager: ${ALERTMANAGER_URL:-pending}"

# ── PHASE 4.5: Build & push MCP server image ─────────────────────────────────
hdr "Phase 4.5 — MCP server image"

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
hdr "Phase 5 — Workshop services"

# Namespace
kubectl apply -f "$WORKSHOP_DIR/namespace.yaml" >> "$LOG_FILE" 2>&1
ok "Namespace: workshop"

# kubeconfig secret for MCP
kubectl create secret generic workshop-kubeconfig \
  --from-file=config="$KUBECONFIG_PATH" \
  -n workshop --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
ok "kubeconfig secret"

# TOTP + write token — auto-generated, no student input needed
TOTP_SECRET=$(python3 -c "import pyotp; print(pyotp.random_base32())" 2>/dev/null || \
              openssl rand -base64 20 | tr -d '+=/' | cut -c1-32)
WRITE_TOKEN=$(openssl rand -hex 32)

kubectl create secret generic mcp-secrets \
  --from-literal=TOTP_SECRET="$TOTP_SECRET" \
  --from-literal=WRITE_APPROVAL_TOKEN="$WRITE_TOKEN" \
  -n workshop --dry-run=client -o yaml | kubectl apply -f - >> "$LOG_FILE" 2>&1
ok "MCP secrets (TOTP auto-generated)"

# n8n
sed "s|INJECT_N8N_HOST|$INGRESS_LB|g; \
     s|INJECT_N8N_PASSWORD|changeme123|g; \
     s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL:-http://prometheus-pending}|g" \
  "$WORKSHOP_DIR/n8n/configmap.yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1
kubectl apply -f "$WORKSHOP_DIR/n8n/pvc.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$WORKSHOP_DIR/n8n/deployment.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$WORKSHOP_DIR/n8n/service.yaml" >> "$LOG_FILE" 2>&1
ok "n8n"

# MCP server
sed "s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL:-http://prometheus-pending}|g" \
  "$WORKSHOP_DIR/mcp-server/configmap.yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1
kubectl apply -f "$WORKSHOP_DIR/mcp-server/pvc.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$WORKSHOP_DIR/mcp-server/deployment.yaml" >> "$LOG_FILE" 2>&1
kubectl apply -f "$WORKSHOP_DIR/mcp-server/service.yaml" >> "$LOG_FILE" 2>&1
ok "MCP server"

# Dashboard
sed "s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL:-}|g; \
     s|INJECT_GRAFANA_URL|${GRAFANA_URL:-}|g; \
     s|INJECT_ALERTMANAGER_URL|${ALERTMANAGER_URL:-}|g; \
     s|INJECT_INGRESS_LB|${INGRESS_LB}|g" \
  "$WORKSHOP_DIR/dashboard/configmap.yaml" | kubectl apply -f - >> "$LOG_FILE" 2>&1
kubectl apply -f "$WORKSHOP_DIR/dashboard/deployment.yaml" >> "$LOG_FILE" 2>&1
ok "Dashboard"

# Target app
kubectl apply -f "$WORKSHOP_DIR/target-app/deployment.yaml" >> "$LOG_FILE" 2>&1
ok "target-app"

# ── PHASE 6: Ingress rules ────────────────────────────────────────────────────
hdr "Phase 6 — Ingress rules"
# Delete old single ingress if exists (avoid duplicate path conflicts)
kubectl delete ingress workshop-ingress -n workshop 2>/dev/null || true
kubectl apply -f "$INGRESS_DIR/ingress.yaml" >> "$LOG_FILE" 2>&1
ok "Ingress rules applied"

# ── PHASE 7: Wait for pods ────────────────────────────────────────────────────
hdr "Phase 7 — Waiting for pods"
info "Waiting for n8n (up to 2 min)..."
kubectl rollout status deployment/n8n -n workshop --timeout=120s >> "$LOG_FILE" 2>&1 \
  && ok "n8n ready" || warn "n8n not ready yet — check: kubectl get pods -n workshop"
kubectl rollout status deployment/mcp-server -n workshop --timeout=120s >> "$LOG_FILE" 2>&1 \
  && ok "mcp-server ready" || warn "mcp-server not ready yet"
kubectl rollout status deployment/clawops-dashboard -n workshop --timeout=60s >> "$LOG_FILE" 2>&1 \
  && ok "dashboard ready" || warn "dashboard not ready yet"
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
  "kubectl get pods -n workshop -l app=n8n --field-selector=status.phase=Running | grep -q n8n"
check "mcp-server pod running" \
  "kubectl get pods -n workshop -l app=mcp-server --field-selector=status.phase=Running | grep -q mcp"
check "dashboard pod running" \
  "kubectl get pods -n workshop -l app=clawops-dashboard --field-selector=status.phase=Running | grep -q clawops"
check "target-app pod running" \
  "kubectl get pods -n workshop -l app=target-app --field-selector=status.phase=Running | grep -q target"

# Internal connectivity (from within cluster via kubectl exec)
N8N_POD=$(kubectl get pods -n workshop -l app=n8n -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
MCP_POD=$(kubectl get pods -n workshop -l app=mcp-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

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
  "curl -sf --max-time 10 http://${INGRESS_LB}/ | grep -qi clawops"
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
echo -e "  📈  Prometheus:   ${PROMETHEUS_URL:-http://${INGRESS_LB}/prometheus}"
echo -e "  📊  Grafana:      ${GRAFANA_URL:-http://${INGRESS_LB}/grafana}  (admin/workshop123)"
echo -e "  🔔  Alertmanager: ${ALERTMANAGER_URL:-pending}"
echo ""
echo -e "${YELLOW}  📋  INSTRUCTOR — TOTP secret (add to Authy for live demos):${NC}"
echo -e "  TOTP_SECRET=${TOTP_SECRET}"
echo ""
echo -e "${CYAN}  Student setup (2 min):${NC}"
echo -e "  1. Open http://${INGRESS_LB}/n8n → Credentials → add Gemini API key"
echo -e "  2. Import workflows from /n8n-workflows/"
echo -e "  3. Open http://${INGRESS_LB}/ → ready ✅"
echo ""
warn "DNS propagation for LB hostname can take 1-2 min — if URLs don't load yet, wait and retry"
echo ""
echo -e "  Full log: $LOG_FILE"
