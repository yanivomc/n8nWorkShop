#!/bin/bash
# Run on student EC2 after provisioning
set -e
echo "=== n8n Workshop Bootstrap ==="

# Install Docker
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install VS Code Server (browser-based)
curl -fsSL https://code-server.dev/install.sh | sh
systemctl enable --now code-server@ubuntu

# Clone workshop repo
sudo -u ubuntu git clone https://github.com/yanivomc/n8nWorkShop.git /home/ubuntu/n8nWorkShop
cd /home/ubuntu/n8nWorkShop/student-env
sudo -u ubuntu cp .env.example .env

echo ""
echo "=== Bootstrap complete ==="
echo "VS Code: http://<EC2_IP>:8080"
echo "n8n:     http://<EC2_IP>:5678  (after: cd n8nWorkShop/student-env && docker-compose up -d)"
echo "MCP:     http://<EC2_IP>:8000/docs"
