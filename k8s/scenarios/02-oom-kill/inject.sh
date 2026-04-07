#!/bin/bash
# Scenario 02: OOMKill — 200MB into a 100MB limit pod
NAMESPACE=${1:-prod}
SCRIPT_DIR=$(dirname "$0")
echo "==> Injecting OOMKill into: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f $SCRIPT_DIR/deploy.yaml -n $NAMESPACE
echo ""
echo "Watch:    kubectl get pods -n $NAMESPACE -l app=memory-hog -w"
echo "Describe: kubectl describe pod -n $NAMESPACE -l app=memory-hog"
echo "Cleanup:  $SCRIPT_DIR/cleanup.sh $NAMESPACE"
