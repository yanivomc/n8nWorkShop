#!/bin/bash
NAMESPACE=${1:-prod}
kubectl delete deployment memory-hog -n $NAMESPACE --ignore-not-found
echo "Done"
