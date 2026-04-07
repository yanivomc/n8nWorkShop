#!/bin/bash
# Scenario 03: Pending pods — requests exceed node capacity
NAMESPACE=${1:-prod}
SCRIPT_DIR=$(dirname "$0")
echo "==> Injecting pending pod scenario into: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f $SCRIPT_DIR/deploy.yaml -n $NAMESPACE
echo ""
echo "Pending: kubectl get pods -n $NAMESPACE -l app=resource-hungry"
echo "Why:     kubectl describe pod -n $NAMESPACE -l app=resource-hungry"
echo "Nodes:   kubectl describe nodes | grep -A5 'Allocated resources'"
echo "Cleanup: $SCRIPT_DIR/cleanup.sh $NAMESPACE"
