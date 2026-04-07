#!/bin/bash
# n8n Workshop — Student Setup
# Run once after cloning the repo on your EC2 instance.
set -e

echo ""
echo "========================================"
echo "  n8n DevOps Workshop — Student Setup"
echo "========================================"
echo ""

# ── 1. Collect inputs ─────────────────────────────────────────────────
read -p "Enter your cluster master PUBLIC IP (e.g. 54.216.99.31): " MASTER_IP
read -p "Enter your kubeconfig download URL (presigned S3 URL):    " KUBECONFIG_URL

if [[ -z "$MASTER_IP" || -z "$KUBECONFIG_URL" ]]; then
  echo "ERROR: Both values are required."
  exit 1
fi

# ── 2. Install kubectl ────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  echo ""
  echo "==> Installing kubectl..."
  KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
  echo "    kubectl $(kubectl version --client --short 2>/dev/null || kubectl version --client) installed OK"
else
  echo "==> kubectl already installed: $(kubectl version --client --short 2>/dev/null | head -1)"
fi

# ── 3. Download kubeconfig ────────────────────────────────────────────
echo ""
echo "==> Downloading kubeconfig..."
mkdir -p ~/.kube
curl -sL "$KUBECONFIG_URL" -o ~/.kube/config
chmod 600 ~/.kube/config
echo "    Saved to ~/.kube/config"

# ── 4. Extract cluster hostname from kubeconfig ───────────────────────
# kops clusters use a DNS name like api.yaniv1.jb.io
CLUSTER_HOST=$(grep -oP 'https://\K[^:]+' ~/.kube/config | head -1)
if [[ -z "$CLUSTER_HOST" ]]; then
  echo "WARNING: Could not extract cluster hostname from kubeconfig"
  CLUSTER_HOST="api.cluster.local"
fi
echo "    Cluster API host: $CLUSTER_HOST"

# ── 5. Add /etc/hosts entry on EC2 ───────────────────────────────────
echo ""
echo "==> Patching /etc/hosts for cluster DNS ($CLUSTER_HOST -> $MASTER_IP)..."
# Remove any previous entry for this host
sudo sed -i "/$CLUSTER_HOST/d" /etc/hosts
echo "$MASTER_IP $CLUSTER_HOST" | sudo tee -a /etc/hosts > /dev/null
echo "    Added: $MASTER_IP $CLUSTER_HOST"

# ── 6. Write .env if not exists ───────────────────────────────────────
SCRIPT_DIR=$(dirname "$0")
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  echo ""
  echo "==> Created .env from .env.example"
fi

# Inject MASTER_IP and CLUSTER_HOST into .env for docker-compose use
sed -i "s|^MASTER_IP=.*|MASTER_IP=$MASTER_IP|" "$SCRIPT_DIR/.env" 2>/dev/null || \
  echo "MASTER_IP=$MASTER_IP" >> "$SCRIPT_DIR/.env"

sed -i "s|^CLUSTER_HOST=.*|CLUSTER_HOST=$CLUSTER_HOST|" "$SCRIPT_DIR/.env" 2>/dev/null || \
  echo "CLUSTER_HOST=$CLUSTER_HOST" >> "$SCRIPT_DIR/.env"

# ── 7. Test cluster connectivity ──────────────────────────────────────
echo ""
echo "==> Testing cluster connectivity..."
if kubectl get nodes 2>&1; then
  echo "    Cluster connection: OK"
else
  echo "    WARNING: Cannot connect to cluster yet."
  echo "    Possible causes: security group, VPN, or the presigned URL expired."
fi

# ── 8. Done ───────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  Setup complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Edit .env  — add GEMINI_API_KEY, TELEGRAM_BOT_TOKEN, WRITE_APPROVAL_TOKEN"
echo "  2. docker-compose up -d"
echo "  3. n8n:    http://localhost:5678"
echo "  4. MCP:    http://localhost:8000/docs"
echo "  5. Test:   curl http://localhost:8000/health"
echo ""
