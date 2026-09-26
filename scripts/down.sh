#!/usr/bin/env bash
# Delete the practice cluster.
set -euo pipefail
kind delete cluster --name "${CLUSTER_NAME:-ckad}"
