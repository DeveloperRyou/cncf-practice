#!/usr/bin/env bash
# Round 02 setup: recreate every r02-* namespace from scratch (idempotent;
# re-running wipes any work done in them).
set -euo pipefail

NAMESPACES=(r02-q1 r02-q2 r02-q3 r02-q4 r02-q5)

kubectl delete namespace "${NAMESPACES[@]}" --ignore-not-found --wait=true
for ns in "${NAMESPACES[@]}"; do kubectl create namespace "$ns"; done

# --- Q2: the current version behind Service shop, plus the canary's page ----
kubectl apply -n r02-q2 -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: html-v1
data:
  index.html: "shop v1\n"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: html-v2
data:
  index.html: "shop v2\n"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-v1
spec:
  replicas: 4
  selector:
    matchLabels: {app: shop, version: v1}
  template:
    metadata:
      labels: {app: shop, version: v1}
    spec:
      volumes:
        - name: html
          configMap: {name: html-v1}
      containers:
        - name: nginx
          image: nginx:1.26-alpine
          ports: [{containerPort: 80}]
          volumeMounts:
            - {name: html, mountPath: /usr/share/nginx/html}
---
apiVersion: v1
kind: Service
metadata:
  name: shop
spec:
  selector: {app: shop, version: v1}
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client
spec:
  containers:
    - {name: main, image: busybox:1.36, command: ["sleep", "infinity"]}
YAML

# --- Q3: a container that can't start, and one that runs out of memory -------
kubectl apply -n r02-q3 -f - <<'YAML'
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
          command: ["/bin/sh -c", "while true; do echo working; sleep 5; done"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache-warmer
spec:
  replicas: 1
  selector:
    matchLabels: {app: cache-warmer}
  template:
    metadata:
      labels: {app: cache-warmer}
    spec:
      containers:
        - name: warmer
          image: busybox:1.36
          command: ["sh", "-c", "head -c 40m /dev/zero | tail; echo warmed; sleep 3600"]
          resources:
            requests: {memory: 16Mi}
            limits: {memory: 24Mi}
YAML

# --- Q4: a quota that rejects pods without resources ------------------------
kubectl apply -n r02-q4 -f - <<'YAML'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
spec:
  hard:
    pods: "6"
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 1Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: api-token
type: Opaque
stringData:
  token: c2VjcmV0LXRva2Vu
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: report
spec:
  replicas: 2
  selector:
    matchLabels: {app: report}
  template:
    metadata:
      labels: {app: report}
    spec:
      containers:
        - name: report
          image: nginx:1.27-alpine
          ports: [{containerPort: 80}]
YAML

# --- Q5: two backends and two client pods -----------------------------------
for app in a b; do
  kubectl apply -n r02-q5 -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-$app
spec:
  replicas: 2
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
kubectl run client -n r02-q5 --image=busybox:1.36 --labels=role=client -- sleep infinity
kubectl run other -n r02-q5 --image=busybox:1.36 --labels=role=other -- sleep infinity

kubectl wait -n r02-q2 --for=condition=Ready pod --all --timeout=180s
kubectl wait -n r02-q5 --for=condition=Ready pod --all --timeout=180s

echo
echo "setup done -- open ckad/round-02/README.md"
