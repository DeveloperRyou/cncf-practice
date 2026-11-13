#!/usr/bin/env bash
# Round 03 setup: recreate every r03-* namespace and the node-level state
# (idempotent; re-running resets the round).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"
WORK="$DIR/workdir"
NAMESPACES=(r03-q1 r03-q2 r03-q3 r03-q4 r03-q5 r03-q5-staging)
SCHED=/etc/kubernetes/manifests/kube-scheduler.yaml

# Undo a previous run first: a working scheduler, default static pod path.
node "$CP" "sed -i 's#/etc/kubernetes/scheduler.config#/etc/kubernetes/scheduler.conf#' $SCHED"
node "$W2" 'rm -rf /etc/kubernetes/static
  sed -i "s#^staticPodPath: .*#staticPodPath: /etc/kubernetes/manifests#" /var/lib/kubelet/config.yaml
  rm -f /etc/kubernetes/manifests/*.yaml; systemctl restart kubelet'
kubectl -n kube-system wait --for=condition=Ready pod -l component=kube-scheduler --timeout=120s >/dev/null
kubectl delete namespace "${NAMESPACES[@]}" --ignore-not-found --wait=true
kubectl delete clusterrolebinding deployer-all deployer-node-reader --ignore-not-found
kubectl delete clusterrole deploy-manager node-reader --ignore-not-found
for ns in "${NAMESPACES[@]}"; do kubectl create namespace "$ns"; done
rm -rf "$WORK"; mkdir -p "$WORK"
prep_nodes

# --- Q2: static pods on worker2 come from a non-default directory -----------
node "$W2" 'mkdir -p /etc/kubernetes/static
  sed -i "s#^staticPodPath: .*#staticPodPath: /etc/kubernetes/static#" /var/lib/kubelet/config.yaml
  systemctl restart kubelet'

# --- Q4: a Service that selects nothing -------------------------------------
kubectl apply -n r03-q4 -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop
spec:
  replicas: 2
  selector:
    matchLabels: {app: shop, tier: web}
  template:
    metadata:
      labels: {app: shop, tier: web}
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports: [{name: http, containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata:
  name: shop
spec:
  selector: {app: shop-web}
  ports: [{port: 80, targetPort: 8080}]
YAML
kubectl create deployment static -n r03-q4 --image=nginx:1.27-alpine >/dev/null
kubectl expose deployment static -n r03-q4 --port=80 >/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=shop.example.com" \
  -keyout "$WORK/shop.key" -out "$WORK/shop.crt" 2>/dev/null

# --- Q5: a ServiceAccount with far too much access --------------------------
kubectl create serviceaccount deployer -n r03-q5 >/dev/null
kubectl create clusterrolebinding deployer-all --clusterrole=edit --serviceaccount=r03-q5:deployer >/dev/null

kubectl wait -n r03-q4 --for=condition=Available deploy --all --timeout=120s >/dev/null

# --- Q1: the scheduler can't start; new pods stay Pending -------------------
node "$CP" "sed -i 's#--kubeconfig=/etc/kubernetes/scheduler.conf#--kubeconfig=/etc/kubernetes/scheduler.config#' $SCHED"
# Wait until the kubelet has replaced the scheduler before creating pods.
while node "$CP" 'crictl ps --name kube-scheduler -q | grep -q .'; do sleep 2; done
kubectl create deployment queue -n r03-q1 --image=nginx:1.27-alpine --replicas=2 >/dev/null

echo "round 03 ready"
