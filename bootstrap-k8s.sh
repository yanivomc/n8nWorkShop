#!/bin/bash
# ── ClawOps Full K8s Bootstrap ────────────────────────────────────────────────
# Deploys everything to K8s: ingress-nginx, n8n, mcp-server, dashboard, target-app
# Usage: bash bootstrap-k8s.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/student-env/.env"
WORKSHOP_DIR="$SCRIPT_DIR/k8s/workshop"
INGRESS_DIR="$SCRIPT_DIR/k8s/ingress"
MONITORING_DIR="$SCRIPT_DIR/k8s/monitoring"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
err()  { echo -e "${RED}  ❌ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}  ⚠️  $1${NC}"; }
hdr()  { echo -e "\n${BOLD}${CYAN}  ── $1 ──${NC}"; }

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || err ".env not found — run setup.sh option 2 first"

# ── Validate required vars ────────────────────────────────────────────────────
[[ -z "$TOTP_SECRET" ]]           && err "TOTP_SECRET not set — run setup.sh option 2"
[[ -z "$WRITE_APPROVAL_TOKEN" ]]  && err "WRITE_APPROVAL_TOKEN not set — run setup.sh option 2"
[[ -z "$N8N_PASSWORD" ]]          && N8N_PASSWORD="changeme123"

# ── Step 1: Install ingress-nginx via Helm ────────────────────────────────────
hdr "Step 1 — Installing ingress-nginx"
if ! helm repo list 2>/dev/null | grep -q "ingress-nginx"; then
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update
fi

if helm status ingress-nginx -n ingress-nginx &>/dev/null 2>&1; then
  ok "ingress-nginx already installed — skipping"
else
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx --create-namespace \
    -f "$INGRESS_DIR/ingress-nginx-values.yaml" \
    --wait --timeout 3m
  ok "ingress-nginx installed"
fi

# ── Step 2: Wait for ingress LB ───────────────────────────────────────────────
hdr "Step 2 — Waiting for ingress LoadBalancer IP"
echo "  Waiting for LB address (up to 90s)..."
INGRESS_LB=""
for i in $(seq 1 18); do
  INGRESS_LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || \
    kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ -n "$INGRESS_LB" ]] && break
  sleep 5
  echo -n "."
done
echo ""
[[ -z "$INGRESS_LB" ]] && err "Ingress LB not ready — check: kubectl get svc -n ingress-nginx"
ok "Ingress LB: $INGRESS_LB"

# Save LB to .env for reference
grep -q "INGRESS_LB" "$ENV_FILE" && \
  sed -i "s|INGRESS_LB=.*|INGRESS_LB='$INGRESS_LB'|" "$ENV_FILE" || \
  echo "INGRESS_LB='$INGRESS_LB'" >> "$ENV_FILE"

# ── Step 3: Install Prometheus + Grafana (if not already installed) ───────────
hdr "Step 3 — Monitoring stack"
if helm status monitoring -n monitoring &>/dev/null 2>&1; then
  ok "Monitoring already installed"
  # Refresh LB URLs
  PROMETHEUS_URL="http://$(kubectl get svc monitoring-kube-prometheus-prometheus -n monitoring \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null):9090"
  GRAFANA_URL="http://$(kubectl get svc monitoring-grafana -n monitoring \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  ALERTMANAGER_URL="http://$(kubectl get svc monitoring-kube-prometheus-alertmanager -n monitoring \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null):9093"
else
  echo "  Installing kube-prometheus-stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update &>/dev/null

  # Patch alertmanager webhook → internal n8n service (no EC2 IP needed!)
  sed "s|EC2_PUBLIC_IP_PLACEHOLDER|n8n.workshop.svc.cluster.local|g" \
    "$MONITORING_DIR/prometheus-values.yaml" > /tmp/prom-values.yaml

  helm install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f /tmp/prom-values.yaml \
    --wait --timeout 5m
  ok "Monitoring installed"

  # Wait for LBs
  echo "  Waiting for monitoring LBs..."
  for i in $(seq 1 12); do
    PROMETHEUS_URL="http://$(kubectl get svc monitoring-kube-prometheus-prometheus -n monitoring \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null):9090"
    [[ "$PROMETHEUS_URL" != "http://:9090" ]] && break
    sleep 5
  done
fi

ok "Prometheus:   $PROMETHEUS_URL"
ok "Grafana:      $GRAFANA_URL"
ok "Alertmanager: $ALERTMANAGER_URL"

# Save to .env
for VAR in PROMETHEUS_URL GRAFANA_URL ALERTMANAGER_URL; do
  VAL="${!VAR}"
  grep -q "^${VAR}=" "$ENV_FILE" && \
    sed -i "s|^${VAR}=.*|${VAR}='${VAL}'|" "$ENV_FILE" || \
    echo "${VAR}='${VAL}'" >> "$ENV_FILE"
done

# ── Step 4: Deploy workshop namespace + services ──────────────────────────────
hdr "Step 4 — Workshop services"

kubectl apply -f "$WORKSHOP_DIR/namespace.yaml"

# Create MCP secrets
cat > /tmp/mcp-secret.yaml << SECRETEOF
apiVersion: v1
kind: Secret
metadata:
  name: mcp-secrets
  namespace: workshop
type: Opaque
stringData:
  TOTP_SECRET: "${TOTP_SECRET}"
  WRITE_APPROVAL_TOKEN: "${WRITE_APPROVAL_TOKEN}"
SECRETEOF
kubectl apply -f /tmp/mcp-secret.yaml
rm /tmp/mcp-secret.yaml
ok "MCP secrets created"

# Create kubeconfig secret for MCP server
kubectl create secret generic workshop-kubeconfig \
  --from-file=config="${KUBECONFIG_PATH:-$HOME/.kube/config}" \
  -n workshop --dry-run=client -o yaml | kubectl apply -f -
ok "kubeconfig secret created"

# Patch and apply n8n configmap
N8N_WEBHOOK_URL="http://${INGRESS_LB}/n8n"
sed "s|INJECT_N8N_HOST|${INGRESS_LB}|g; \
     s|INJECT_N8N_PASSWORD|${N8N_PASSWORD}|g; \
     s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL}|g" \
  "$WORKSHOP_DIR/n8n/configmap.yaml" | kubectl apply -f -

# Apply n8n
kubectl apply -f "$WORKSHOP_DIR/n8n/pvc.yaml"
kubectl apply -f "$WORKSHOP_DIR/n8n/deployment.yaml"
kubectl apply -f "$WORKSHOP_DIR/n8n/service.yaml"
ok "n8n deployed"

# Patch and apply MCP configmap
sed "s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL}|g" \
  "$WORKSHOP_DIR/mcp-server/configmap.yaml" | kubectl apply -f -

# Apply MCP server
kubectl apply -f "$WORKSHOP_DIR/mcp-server/pvc.yaml"
kubectl apply -f "$WORKSHOP_DIR/mcp-server/deployment.yaml"
kubectl apply -f "$WORKSHOP_DIR/mcp-server/service.yaml"
ok "MCP server deployed"

# Patch and apply dashboard configmap
sed "s|INJECT_PROMETHEUS_URL|${PROMETHEUS_URL}|g; \
     s|INJECT_GRAFANA_URL|${GRAFANA_URL}|g; \
     s|INJECT_ALERTMANAGER_URL|${ALERTMANAGER_URL}|g" \
  "$WORKSHOP_DIR/dashboard/configmap.yaml" | kubectl apply -f -

kubectl apply -f "$WORKSHOP_DIR/dashboard/deployment.yaml"
ok "Dashboard deployed"

# Apply target-app
kubectl apply -f "$WORKSHOP_DIR/target-app/deployment.yaml"
ok "target-app deployed"

# ── Step 5: Apply ingress rules ───────────────────────────────────────────────
hdr "Step 5 — Ingress rules"
kubectl apply -f "$INGRESS_DIR/ingress.yaml"
ok "Ingress rules applied"

# ── Step 6: Wait for pods ─────────────────────────────────────────────────────
hdr "Step 6 — Waiting for pods to be ready"
kubectl rollout status deployment/n8n -n workshop --timeout=120s
kubectl rollout status deployment/mcp-server -n workshop --timeout=120s
kubectl rollout status deployment/clawops-dashboard -n workshop --timeout=60s
kubectl rollout status deployment/target-app -n workshop --timeout=60s
ok "All workshop pods ready"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}  ✅ Bootstrap complete!${NC}"
echo ""
echo -e "${CYAN}  ── Your workshop URLs (all via ONE LB) ──────────────────${NC}"
echo -e "  📊 Dashboard:   http://${INGRESS_LB}/"
echo -e "  🤖 n8n:         http://${INGRESS_LB}/n8n"
echo -e "  🔧 MCP Docs:    http://${INGRESS_LB}/mcp/docs"
echo -e "  📈 Prometheus:  http://${INGRESS_LB}/prometheus"
echo -e "  📊 Grafana:     http://${INGRESS_LB}/grafana  (admin/workshop123)"
echo -e "  🔔 Alertmanager: http://${INGRESS_LB}/alertmanager"
echo ""
echo -e "  🎓 Student setup: Open dashboard URL → set Gemini key in n8n → done!"
echo ""
