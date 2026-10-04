#!/usr/bin/env bash
# Round 05 setup: recreate every r05-* namespace from scratch (idempotent;
# re-running wipes any work done in them).
set -euo pipefail

NAMESPACES=(r05-q1 r05-q2 r05-q3 r05-q4)

kubectl delete namespace "${NAMESPACES[@]}" --ignore-not-found --wait=true
for ns in "${NAMESPACES[@]}"; do kubectl create namespace "$ns"; done

# --- Q2: a quota that rejects pods without resources ------------------------
kubectl apply -n r05-q2 -f - <<'YAML'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
spec:
  hard:
    pods: "5"
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
spec:
  replicas: 2
  selector:
    matchLabels: {app: worker}
  template:
    metadata:
      labels: {app: worker}
    spec:
      containers:
        - name: worker
          image: busybox:1.36
          command: ["sleep", "infinity"]
YAML

# --- Q3: two good revisions, then one stuck on a bad readinessProbe -----------
kubectl apply -n r05-q3 -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  annotations:
    kubernetes.io/change-cause: v1
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 1, maxUnavailable: 0}
  selector:
    matchLabels: {app: api}
  template:
    metadata:
      labels: {app: api}
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports: [{containerPort: 80}]
          readinessProbe:
            httpGet: {path: /, port: 80}
            periodSeconds: 3
YAML
kubectl rollout status deploy/api -n r05-q3 --timeout=180s
kubectl set image deploy/api -n r05-q3 nginx=nginx:1.26-alpine
kubectl annotate deploy/api -n r05-q3 --overwrite kubernetes.io/change-cause=v2
kubectl rollout status deploy/api -n r05-q3 --timeout=180s
kubectl patch deploy/api -n r05-q3 --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:1.27-alpine"},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet","value":{"path":"/ready","port":8080}}]'
kubectl annotate deploy/api -n r05-q3 --overwrite kubernetes.io/change-cause=v3

# --- Q4: three backends, Service db, and two client pods ---------------------
for app in db cache web; do
  kubectl apply -n r05-q4 -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $app
spec:
  replicas: 1
  selector:
    matchLabels: {app: $app}
  template:
    metadata:
      labels: {app: $app}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{containerPort: 80}]
YAML
done
kubectl apply -n r05-q4 -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: db
spec:
  selector: {app: db}
  ports:
    - port: 5432
      targetPort: 80
---
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
kubectl run app -n r05-q4 --image=busybox:1.36 --labels=role=app -- sleep infinity
kubectl run debug -n r05-q4 --image=busybox:1.36 --labels=role=debug -- sleep infinity

kubectl wait -n r05-q4 --for=condition=Ready pod --all --timeout=180s

echo
echo "setup done -- open ckad/round-05/README.md"
