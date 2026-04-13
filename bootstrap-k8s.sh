#!/bin/bash
# ── ClawOps Full K8s Bootstrap ────────────────────────────────────────────────
# Deploys everything to K8s with ONE command.
# No API keys needed — students configure everything in n8n UI.
# Usage: bash bootstrap-k8s.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSHOP_DIR="$SCRIPT_DIR/k8s/workshop"
INGRESS_DIR="$SCRIPT_DIR/k8s/ingress"
MONITORING_DIR="$SCRIPT_DIR/k8s/monitoring"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
err()  { echo -e "${RED}  ❌ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}  ⚠️  $1${NC}"; }
hdr()  { echo -e "\n${BOLD}${CYAN}  ── $1 ──${NC}"; }

# ── Step 1: Install ingress-nginx ─────────────────────────────────────────────
hdr "Step 1 — ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update &>/dev/null
if helm status ingress-nginx -n ingress-nginx &>/dev/null 2>&1; then
  ok "Already installed — skipping"
else
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx --create-namespace \
    -f "$INGRESS_DIR/ingress-nginx-values.yaml" \
    --wait --timeout 3m
  ok "ingress-nginx installed"
fi

# ── Step 2: Get ingress LB ────────────────────────────────────────────────────
hdr "Step 2 — Waiting for ingress LB"
INGRESS_LB=""
for i in $(seq 1 24); do
  INGRESS_LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [[ -z "$INGRESS_LB" ]] && INGRESS_LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ -n "$INGRESS_LB" ]] && break
  echo -n "."; sleep 5
done
echo ""
[[ -z "$INGRESS_LB" ]] && err "Ingress LB not ready"
ok "Ingress LB: $INGRESS_LB"

# ── Step 3: Install Prometheus + Grafana ──────────────────────────────────────
hdr "Step 3 — Monitoring stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update &>/dev/null
if helm status monitoring -n monitoring &>/dev/null 2>&1; then
  ok "Already installed — skipping"
else
  # Alertmanager → n8n via internal K8s service name (no IP needed ever)
  sed "s|EC2_PUBLIC_IP_PLACEHOLDER|n8n.workshop.svc.cluster.local|g" \
    "$MONITORING_DIR/prometheus-values.yaml" > /tmp/prom-values.yaml
  helm install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f /tmp/prom-values.yaml --wait --timeout 5m
  ok "Monitoring installed"
fi

# Get monitoring URLs (may still be pending on first install — that's ok)
PROMETHEUS_URL=$(kubectl get svc monitoring-kube-prometheus-prometheus -n monitoring \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}:9090' 2>/dev/null || echo "")
GRAFANA_URL=$(kubectl get svc monitoring-grafana -n monitoring \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
ALERTMANAGER_URL=$(kubectl get svc monitoring-kube-prometheus-alertmanager -n monitoring \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}:9093' 2>/dev/null || echo "")

# ── Step 4: Workshop namespace + services ────────────────────────────────────
hdr "Step 4 — Workshop services"
kubectl apply -f "$WORKSHOP_DIR/namespace.yaml"

# kubeconfig secret for MCP server (so it can run kubectl)
kubectl create secret generic workshop-kubeconfig \
  --from-file=config="$KUBECONFIG_PATH" \
  -n workshop --dry-run=client -o yaml | kubectl apply -f -
ok "kubeconfig secret"

# MCP secrets — TOTP generated now, students don't need to know it
# They only use n8n TOTP approval which reads from this secret
TOTP_SECRET=$(python3 -c "import pyotp; print(pyotp.random_base32())" 2>/dev/null || \
              openssl rand -base64 20 | tr -d '+=/' | head -c 32)
WRITE_TOKEN=$(openssl rand -hex 32)

kubectl create secret generic mcp-secrets \
  --from-literal=TOTP_SECRET="$TOTP_SECRET" \
  --from-literal=WRITE_APPROVAL_TOKEN="$WRITE_TOKEN" \
  -n workshop --dry-run=client -o yaml | kubectl apply -f -
ok "MCP secrets (TOTP auto-generated)"

# Save TOTP for instructor reference only
echo ""
echo -e "${YELLOW}  📋 INSTRUCTOR ONLY — TOTP Secret (add to Authy for demos):${NC}"
echo -e "  TOTP_SECRET=$TOTP_SECRET"
echo ""

# n8n — webhook URL uses ingress LB
sed "s|INJECT_N8N_HOST|$INGRESS_LB|g; \
     s|INJECT_N8N_PASSWORD|changeme123|g; \
     s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL:-http://prometheus-pending}|g" \
  "$WORKSHOP_DIR/n8n/configmap.yaml" | kubectl apply -f -
kubectl apply -f "$WORKSHOP_DIR/n8n/pvc.yaml"
kubectl apply -f "$WORKSHOP_DIR/n8n/deployment.yaml"
kubectl apply -f "$WORKSHOP_DIR/n8n/service.yaml"
ok "n8n"

# MCP server
sed "s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL:-http://prometheus-pending}|g" \
  "$WORKSHOP_DIR/mcp-server/configmap.yaml" | kubectl apply -f -
kubectl apply -f "$WORKSHOP_DIR/mcp-server/pvc.yaml"
kubectl apply -f "$WORKSHOP_DIR/mcp-server/deployment.yaml"
kubectl apply -f "$WORKSHOP_DIR/mcp-server/service.yaml"
ok "MCP server"

# Dashboard
sed "s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL:-}|g; \
     s|INJECT_GRAFANA_URL|${GRAFANA_URL:-}|g; \
     s|INJECT_ALERTMANAGER_URL|${ALERTMANAGER_URL:-}|g" \
  "$WORKSHOP_DIR/dashboard/configmap.yaml" | kubectl apply -f -
kubectl apply -f "$WORKSHOP_DIR/dashboard/deployment.yaml"
ok "Dashboard"

# Target app
kubectl apply -f "$WORKSHOP_DIR/target-app/deployment.yaml"
ok "target-app"

# ── Step 5: Ingress rules ─────────────────────────────────────────────────────
hdr "Step 5 — Ingress rules"
kubectl apply -f "$INGRESS_DIR/ingress.yaml"
ok "Ingress applied"

# ── Step 6: Wait for pods ─────────────────────────────────────────────────────
hdr "Step 6 — Waiting for pods"
kubectl rollout status deployment/n8n -n workshop --timeout=120s
kubectl rollout status deployment/mcp-server -n workshop --timeout=120s
kubectl rollout status deployment/clawops-dashboard -n workshop --timeout=60s
kubectl rollout status deployment/target-app -n workshop --timeout=60s
ok "All pods ready"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}  ════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅  Bootstrap complete!${NC}"
echo -e "${BOLD}${GREEN}  ════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}  ONE LB — all services:${NC}"
echo -e "  📊 Dashboard:    http://${INGRESS_LB}/"
echo -e "  🤖 n8n:          http://${INGRESS_LB}/n8n"
echo -e "  🔧 MCP Docs:     http://${INGRESS_LB}/mcp/docs"
echo -e "  📈 Prometheus:   http://${INGRESS_LB}/prometheus  (or LB above)"
echo -e "  📊 Grafana:      http://${INGRESS_LB}/grafana      (admin/workshop123)"
echo ""
echo -e "${CYAN}  Student setup (2 min total):${NC}"
echo -e "  1. Open http://${INGRESS_LB}/n8n → set Gemini API key in credentials"
echo -e "  2. Import workflows from /n8n-workflows/"
echo -e "  3. Open http://${INGRESS_LB}/ → Dashboard ready"
echo -e "  4. Done ✅"
echo ""
