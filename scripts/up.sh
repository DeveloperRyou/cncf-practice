#!/usr/bin/env bash
# Create the practice cluster (if missing) and wait until it can run pods.
set -euo pipefail

NAME="${CLUSTER_NAME:-ckad}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

docker info >/dev/null 2>&1 || { echo "Docker is not reachable -- start Docker Desktop (WSL integration on)." >&2; exit 1; }

if kind get clusters | grep -qx "$NAME"; then
  echo "cluster '$NAME' already exists"
else
  kind create cluster --name "$NAME" --config "$ROOT/kind/ckad.yaml"
fi

kubectl config use-context "kind-$NAME" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s
# The default ServiceAccount appears a few seconds after the node is Ready;
# creating a pod before that fails with "serviceaccount default not found".
until kubectl get serviceaccount default >/dev/null 2>&1; do sleep 2; done
kubectl get nodes
