#!/bin/bash
# Test S5 workflow via webhook-test endpoint
# Usage: ./force-s5-test.sh [alertname] [run_id]
# Examples:
#   ./force-s5-test.sh TargetAppCPUStress test-001
#   ./force-s5-test.sh TargetAppMemoryLeak test-002
#   ./force-s5-test.sh TargetAppMemoryCritical test-003

# Load from .env if not set in environment
[ -f "$(dirname "$0")/../../student-env/.env" ] && source "$(dirname "$0")/../../student-env/.env"
NGROK_URL="${WEBHOOK_URL:-${NGROK_URL:-}}"
ALERTNAME="${1:-TargetAppCPUStress}"
RUN_ID="${2:-test-$(date +%s)}"
NAMESPACE="workshop"
POD=$(kubectl get pod -n workshop -l app=target-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "target-app-unknown")

if [ -z "$NGROK_URL" ]; then
  echo "ERROR: WEBHOOK_URL not set. Run setup.sh option 3 first."
  exit 1
fi
echo "→ Sending test alert: $ALERTNAME (run_id=$RUN_ID)"
echo "→ Pod: $POD"

curl -s -X POST "${NGROK_URL}/webhook-test/prometheus-alert-s5" \
  -H "Content-Type: application/json" \
  -d "{
  \"body\": {
    \"receiver\": \"n8n-webhook\",
    \"status\": \"firing\",
    \"alerts\": [{
      \"status\": \"firing\",
      \"labels\": {
        \"alertname\": \"${ALERTNAME}\",
        \"namespace\": \"${NAMESPACE}\",
        \"pod\": \"${POD}\",
        \"severity\": \"critical\",
        \"workshop\": \"true\",
        \"run_id\": \"${RUN_ID}\"
      },
      \"annotations\": {
        \"summary\": \"${ALERTNAME} on ${POD}\",
        \"description\": \"Chaos scenario active on ${POD}\"
      },
      \"startsAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
      \"endsAt\": \"0001-01-01T00:00:00Z\"
    }],
    \"commonLabels\": {
      \"alertname\": \"${ALERTNAME}\",
      \"namespace\": \"${NAMESPACE}\",
      \"pod\": \"${POD}\",
      \"workshop\": \"true\"
    },
    \"commonAnnotations\": {
      \"summary\": \"${ALERTNAME} on ${POD}\",
      \"description\": \"Chaos scenario active on ${POD}\"
    }
  }
}"
echo ""
echo "✓ Sent. Check n8n executions and Telegram."
