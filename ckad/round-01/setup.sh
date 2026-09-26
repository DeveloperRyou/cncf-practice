#!/usr/bin/env bash
# Round 01 setup: recreate every r01-* namespace from scratch (idempotent;
# re-running wipes any work done in them).
set -euo pipefail

NAMESPACES=(r01-q1 r01-q2 r01-q3 r01-q4 r01-q5 r01-q5-mon r01-q5-ext)

kubectl delete namespace "${NAMESPACES[@]}" --ignore-not-found --wait=true
for ns in "${NAMESPACES[@]}"; do kubectl create namespace "$ns"; done
kubectl label namespace r01-q5-mon purpose=monitoring

# --- Q2: a deployment whose latest rollout is stuck on a bad image ---------
kubectl apply -n r01-q2 -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  annotations:
    kubernetes.io/change-cause: initial release
spec:
  replicas: 3
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports: [{containerPort: 80}]
YAML
kubectl rollout status deploy/web -n r01-q2 --timeout=180s
kubectl set image deploy/web -n r01-q2 nginx=nginx:1.99-alpine
kubectl annotate deploy/web -n r01-q2 --overwrite kubernetes.io/change-cause="bump to 1.99-alpine"

# --- Q3: probes that never pass, plus a crashing pod ------------------------
kubectl apply -n r01-q3 -f - <<'YAML'
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
        - name: api
          image: nginx:1.27-alpine
          ports: [{name: http, containerPort: 80}]
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 5
          livenessProbe:
            httpGet: {path: /, port: 8081}
            initialDelaySeconds: 3
            periodSeconds: 5
            failureThreshold: 2
---
apiVersion: v1
kind: Pod
metadata:
  name: crasher
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sh", "-c", "echo starting; sleep 2; exit 3"]
YAML

# --- Q5: backend with a broken Service, and client pods ---------------------
kubectl apply -n r01-q5 -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 2
  selector:
    matchLabels: {app: backend}
  template:
    metadata:
      labels: {app: backend, tier: api}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
spec:
  selector: {app: backend-api}
  ports:
    - port: 80
      targetPort: 8080
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
kubectl run prober -n r01-q5-mon --image=busybox:1.36 --labels=role=monitor -- sleep infinity
kubectl run frontend -n r01-q5-ext --image=busybox:1.36 --labels=role=frontend -- sleep infinity

kubectl wait -n r01-q5 --for=condition=Ready pod --all --timeout=180s
kubectl wait -n r01-q5-mon --for=condition=Ready pod --all --timeout=180s
kubectl wait -n r01-q5-ext --for=condition=Ready pod --all --timeout=180s

echo
echo "setup done -- open ckad/round-01/README.md"
