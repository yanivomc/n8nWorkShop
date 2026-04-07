#!/bin/bash
# Scenario 04: ImagePullBackOff — bad image tag
NAMESPACE=${1:-prod}
SCRIPT_DIR=$(dirname "$0")
echo "==> Injecting bad image deployment into: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f $SCRIPT_DIR/deploy.yaml -n $NAMESPACE
echo ""
echo "Status:  kubectl get pods -n $NAMESPACE -l app=bad-image-app"
echo "Events:  kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp"
echo "Cleanup: $SCRIPT_DIR/cleanup.sh $NAMESPACE"
