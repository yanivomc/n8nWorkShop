#!/bin/bash
NAMESPACE=${1:-prod}
kubectl delete deployment bad-image-app -n $NAMESPACE --ignore-not-found
echo "Done"
