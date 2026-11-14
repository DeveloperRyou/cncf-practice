#!/usr/bin/env bash
# Create the practice cluster (if missing) and wait until it can run pods.
#   KIND_CONFIG=kind/cka.yaml ./scripts/up.sh   # node layout (default kind/cluster.yaml)
set -euo pipefail

NAME="${CLUSTER_NAME:-cncf}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${KIND_CONFIG:-$ROOT/kind/cluster.yaml}"
[[ "$CONFIG" = /* ]] || CONFIG="$ROOT/$CONFIG"

if ! docker info >/dev/null 2>&1; then
  hint="start Docker Desktop"
  [ "$(uname -s)" = Linux ] && hint="$hint (WSL integration on)"
  echo "Docker is not reachable -- $hint." >&2
  exit 1
fi

if kind get clusters | grep -qx "$NAME"; then
  echo "cluster '$NAME' already exists"
  # A CKAD (1 node) cluster can't run a CKA (3 node) round and vice versa.
  want=$(grep -c -- '- role:' "$CONFIG")
  have=$(kind get nodes --name "$NAME" | wc -l | tr -d " ")
  [ "$want" = "$have" ] || { echo "cluster '$NAME' has $have node(s) but $(basename "$CONFIG") wants $want -- run ./scripts/down.sh first." >&2; exit 1; }
else
  kind create cluster --name "$NAME" --config "$CONFIG"
fi

kubectl config use-context "kind-$NAME" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s
# The default ServiceAccount appears a few seconds after the node is Ready;
# creating a pod before that fails with "serviceaccount default not found".
until kubectl get serviceaccount default >/dev/null 2>&1; do sleep 2; done
kubectl get nodes
