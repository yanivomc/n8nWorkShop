#!/bin/bash
# Scenario 01: CrashLoopBackOff
# Pod exits every 5s. PodCrashLooping alert fires in ~2 min.
NAMESPACE=${1:-prod}
SCRIPT_DIR=$(dirname "$0")
echo "==> Injecting CrashLoopBackOff into: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f $SCRIPT_DIR/deploy.yaml -n $NAMESPACE
echo ""
echo "Watch:   kubectl get pods -n $NAMESPACE -l app=payments -w"
echo "Cleanup: $SCRIPT_DIR/cleanup.sh $NAMESPACE"
