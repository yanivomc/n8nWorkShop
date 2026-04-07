#!/bin/bash
NAMESPACE=${1:-prod}
kubectl delete deployment resource-hungry -n $NAMESPACE --ignore-not-found
echo "Done"
