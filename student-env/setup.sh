#!/bin/bash
# Student EC2 bootstrap — run once after cloning the repo
set -e

echo '=== n8n Workshop Setup ==='

# Check prerequisites
command -v docker >/dev/null 2>&1 || { echo 'Docker not found. Install Docker first.'; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo 'kubectl not found. Install kubectl first.'; exit 1; }

# Copy env file
if [ ! -f .env ]; then
  cp .env.example .env
  echo 'Created .env from .env.example — fill in your values before starting!'
else
  echo '.env already exists — skipping copy'
fi

# Verify kubeconfig
if kubectl get nodes > /dev/null 2>&1; then
  echo 'Cluster connection: OK'
  kubectl get nodes
else
  echo 'WARNING: Cannot connect to cluster. Check KUBECONFIG_PATH in .env'
fi

echo ''
echo 'Next steps:'
echo '  1. Edit .env with your values (GEMINI_API_KEY, TELEGRAM_BOT_TOKEN, etc.)'
echo '  2. docker-compose up -d'
echo '  3. Open n8n at http://localhost:5678'
echo '  4. Open MCP docs at http://localhost:8000/docs'
echo '  5. Test MCP: curl http://localhost:8000/health'
