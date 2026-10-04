#!/usr/bin/env bash
# Round 04 setup: recreate every r04-* namespace from scratch (idempotent;
# re-running wipes any work done in them, and recreates ckad/round-04/q3).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACES=(r04-q1 r04-q2 r04-q3 r04-q4 r04-q4-mon r04-q4-other)

kubectl delete namespace "${NAMESPACES[@]}" --ignore-not-found --wait=true
for ns in "${NAMESPACES[@]}"; do kubectl create namespace "$ns"; done
kubectl label namespace r04-q4-mon team=monitoring

# --- Q1: the Deployment the CI bot will update --------------------------------
kubectl apply -n r04-q1 -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  replicas: 2
  selector:
    matchLabels: {app: app}
  template:
    metadata:
      labels: {app: app}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{containerPort: 80}]
YAML

# --- Q3: a Kustomize base ---------------------------------------------------
rm -rf "$DIR/q3"
mkdir -p "$DIR/q3/base"
cat > "$DIR/q3/base/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
YAML
cat > "$DIR/q3/base/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: nginx
          image: nginx:1.26-alpine
          ports: [{containerPort: 80}]
YAML
cat > "$DIR/q3/base/service.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector: {app: web}
  ports:
    - port: 80
      targetPort: 80
YAML

# --- Q4: a default deny and a broken allow policy ----------------------------
kubectl apply -n r04-q4 -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 2
  selector:
    matchLabels: {app: api}
  template:
    metadata:
      labels: {app: api}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector: {app: api}
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api
spec:
  podSelector:
    matchLabels: {app: api}
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: {team: monitoring}
          podSelector:
            matchLabels: {role: frontend}
      ports:
        - {protocol: TCP, port: 8080}
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  labels: {role: frontend}
spec:
  containers:
    - {name: main, image: busybox:1.36, command: ["sleep", "infinity"]}
---
apiVersion: v1
kind: Pod
metadata:
  name: intruder
  labels: {role: intruder}
spec:
  containers:
    - {name: main, image: busybox:1.36, command: ["sleep", "infinity"]}
YAML
kubectl run prober -n r04-q4-mon --image=busybox:1.36 --labels=role=prober -- sleep infinity
kubectl run frontend -n r04-q4-other --image=busybox:1.36 --labels=role=frontend -- sleep infinity

kubectl wait -n r04-q1 --for=condition=Ready pod --all --timeout=180s
for ns in r04-q4 r04-q4-mon r04-q4-other; do
  kubectl wait -n "$ns" --for=condition=Ready pod --all --timeout=180s
done

echo
echo "setup done -- open ckad/round-04/README.md"
