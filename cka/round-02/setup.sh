#!/usr/bin/env bash
# Round 02 setup: recreate every r02-* namespace and the cluster-level state
# (idempotent; re-running resets the round).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"
WORK="$DIR/workdir"
NAMESPACES=(r02-q1 r02-q2 r02-q3 r02-q4 r02-q4-ext r02-q5)

kubectl delete namespace "${NAMESPACES[@]}" --ignore-not-found --wait=true
kubectl delete priorityclass ops-critical batch-high batch-low --ignore-not-found
kubectl delete pv mariadb-pv --ignore-not-found
kubectl taint node "$W1" dedicated- >/dev/null 2>&1 || true
kubectl label node "$W1" tier- >/dev/null
for ns in "${NAMESPACES[@]}"; do kubectl create namespace "$ns"; done
rm -rf "$WORK"; mkdir -p "$WORK"
prep_nodes

# --- Q1: an existing Deployment to pin to a dedicated node ------------------
kubectl create priorityclass batch-high --value=500000 --description="nightly batch" >/dev/null
kubectl create priorityclass batch-low --value=1000 --description="best-effort batch" >/dev/null
kubectl create deployment ops-agent -n r02-q1 --image=nginx:1.27-alpine --replicas=2 >/dev/null

# --- Q2: cluster DNS broken, plus a pod that ignores it ---------------------
kubectl -n kube-system get cm coredns -o json \
  | jq '.data.Corefile |= sub("kubernetes cluster.local "; "kubernetes cluster.lcl ") | .data.Corefile |= gsub("\n *hosts \\{[^}]*\\}"; "")' \
  | kubectl apply -f - >/dev/null 2>&1
kubectl -n kube-system rollout restart deploy coredns >/dev/null
kubectl create deployment api -n r02-q2 --image=nginx:1.27-alpine >/dev/null
kubectl expose deployment api -n r02-q2 --port=80 >/dev/null
kubectl apply -n r02-q2 -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: client
spec:
  dnsPolicy: Default
  containers:
  - name: main
    image: busybox:1.36
    command: ["sh", "-c", "sleep 1d"]
---
apiVersion: v1
kind: Pod
metadata:
  name: dns-probe
  labels: {purpose: grading-helper}
spec:
  containers:
  - name: main
    image: busybox:1.36
    command: ["sh", "-c", "sleep 1d"]
YAML

# --- Q3: three CPU burners and an autoscaling target ------------------------
install_metrics_server
burn() {  # burn <name> <shell loop>
  kubectl apply -n r02-q3 -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels: {app: ingest}
spec:
  containers:
  - name: main
    image: busybox:1.36
    command: ["sh", "-c", "$2"]
    resources:
      requests: {cpu: 10m}
      limits: {cpu: 300m}
YAML
}
burn ingest-6c2 'while :; do sleep 1; done'
burn ingest-9fd 'while :; do timeout 1 sh -c \"while :; do :; done\"; sleep 1; done'
burn ingest-b41 'while :; do :; done'
kubectl create deployment api -n r02-q3 --image=nginx:1.27-alpine >/dev/null

# --- Q4: three candidate NetworkPolicies ------------------------------------
for app in backend; do kubectl create deployment "$app" -n r02-q4 --image=nginx:1.27-alpine >/dev/null; done
for p in r02-q4/frontend r02-q4/other r02-q4-ext/frontend; do
  kubectl run "${p#*/}" -n "${p%/*}" --image=busybox:1.36 --labels="app=${p#*/}" -- sleep 1d >/dev/null
done
mkdir -p "$WORK/netpol"
cat > "$WORK/netpol/policy-a.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-ingress-a
spec:
  podSelector:
    matchLabels: {app: backend}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {}
    ports:
    - {protocol: TCP, port: 80}
YAML
cat > "$WORK/netpol/policy-b.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-ingress-b
spec:
  podSelector:
    matchLabels: {app: backend}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {}
      podSelector:
        matchLabels: {app: frontend}
YAML
cat > "$WORK/netpol/policy-c.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-ingress-c
spec:
  podSelector:
    matchLabels: {app: backend}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels: {app: frontend}
    ports:
    - {protocol: TCP, port: 80}
YAML

# --- Q5: a Released PV whose data must be reused -----------------------------
node "$W2" 'mkdir -p /mnt/mariadb && echo data-from-before > /mnt/mariadb/ready'
kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mariadb-pv
spec:
  capacity: {storage: 250Mi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-data
  local: {path: /mnt/mariadb}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: kubernetes.io/hostname, operator: In, values: [$W2]}
YAML
kubectl apply -n r02-q5 -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-old
spec:
  storageClassName: local-data
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 250Mi}
YAML
until [ "$(kubectl get pv mariadb-pv -o jsonpath='{.status.phase}')" = Bound ]; do sleep 1; done
kubectl delete pvc mariadb-old -n r02-q5 >/dev/null
until [ "$(kubectl get pv mariadb-pv -o jsonpath='{.status.phase}')" = Released ]; do sleep 1; done
cat > "$WORK/mariadb.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
  namespace: r02-q5
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app: mariadb}
  template:
    metadata:
      labels: {app: mariadb}
    spec:
      containers:
      - name: mariadb
        # Stand-in for the real database: it only needs its data directory.
        image: busybox:1.36
        command: ["sh", "-c", "cat /var/lib/mysql/ready && sleep 1d"]
YAML

# Pods of Q4 must be up for the policy tests; the metrics need a minute.
kubectl wait -n r02-q4 --for=condition=Ready pod --all --timeout=120s >/dev/null
kubectl wait -n r02-q4-ext --for=condition=Ready pod --all --timeout=120s >/dev/null
for _ in $(seq 36); do kubectl top pods -n r02-q3 >/dev/null 2>&1 && break; sleep 5; done
echo "round 02 ready"
