#!/bin/sh
set -e

# Generate config.js from environment variables
# Dashboard HTML reads window.CLAWOPS_CONFIG on load
cat > /usr/share/nginx/html/config.js << EOF
window.CLAWOPS_CONFIG = {
  prom:         "${PROMETHEUS_URL:-http://localhost:9090}",
  grafana:      "${GRAFANA_URL:-http://localhost:3000}",
  am:           "${ALERTMANAGER_URL:-http://localhost:9093}",
  n8n:          "${N8N_URL:-http://localhost:5678}",
  mcp:          "${MCP_URL:-http://localhost:8000}",
};
EOF

echo "Config injected:"
cat /usr/share/nginx/html/config.js

exec nginx -g "daemon off;"
