#!/bin/bash
# Scenario 05: Flapping — 6 restarts, 30s apart
# Dedup test: Telegram should receive only ONE message
NAMESPACE=${1:-prod}
DEPLOYMENT=${2:-payments-app}
echo "==> Flapping $DEPLOYMENT in $NAMESPACE (6x, 30s apart)"
echo "==> Telegram dedup expected: only 1 message"
for i in 1 2 3 4 5 6; do
  echo "Restart $i/6..."
  kubectl rollout restart deployment/$DEPLOYMENT -n $NAMESPACE
  sleep 30
done
echo "==> Done. Check Telegram."
