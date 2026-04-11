#!/bin/bash
set -e

REGISTRY="${REGISTRY:-localhost:5000}"
IMAGE="${REGISTRY}/target-app:latest"
NAMESPACE="workshop"

echo "▶ Building target-app..."
docker build -t "$IMAGE" .

echo "▶ Pushing $IMAGE..."
docker push "$IMAGE"

echo "▶ Ensuring namespace exists..."
kubectl get namespace "$NAMESPACE" 2>/dev/null || kubectl create namespace "$NAMESPACE"

echo "▶ Deploying to K8s..."
sed "s|TARGET_APP_IMAGE|$IMAGE|g" k8s/deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/servicemonitor.yaml

echo "▶ Waiting for rollout..."
kubectl rollout status deployment/target-app -n "$NAMESPACE" --timeout=60s

echo "✅ Done. App running in namespace: $NAMESPACE"
echo "   kubectl port-forward svc/target-app 8080:8080 -n $NAMESPACE"
