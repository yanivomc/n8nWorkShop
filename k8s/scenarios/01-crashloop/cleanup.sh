#!/bin/bash
NAMESPACE=${1:-prod}
kubectl delete deployment payments-app -n $NAMESPACE --ignore-not-found
echo "Done"
