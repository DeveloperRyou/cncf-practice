#!/usr/bin/env bash
# Round 03 setup: recreate every r03-* namespace from scratch (idempotent;
# re-running wipes any work done in them, and regenerates the chart and TLS
# files in this directory).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NAMESPACES=(r03-q1 r03-q2 r03-q3 r03-q4)

command -v helm >/dev/null || { echo "helm not found -- run ./scripts/install.sh" >&2; exit 1; }

kubectl delete namespace "${NAMESPACES[@]}" --ignore-not-found --wait=true
for ns in "${NAMESPACES[@]}"; do kubectl create namespace "$ns"; done

# --- Q2: a local chart, a release to remove, and a release with a bad upgrade
rm -rf "$DIR/charts"
mkdir -p "$DIR/charts"
helm create "$DIR/charts/webapp" >/dev/null
sed -i 's/^  tag: ""/  tag: "1.26-alpine"/' "$DIR/charts/webapp/values.yaml"
grep -q 'tag: "1.26-alpine"' "$DIR/charts/webapp/values.yaml"
helm install legacy "$DIR/charts/webapp" -n r03-q2 >/dev/null
helm install api "$DIR/charts/webapp" -n r03-q2 --wait --timeout 3m >/dev/null
helm upgrade api "$DIR/charts/webapp" -n r03-q2 --set image.tag=0.0-broken >/dev/null

# --- Q3: a container that exits because a ConfigMap key has the wrong name --
kubectl apply -n r03-q3 -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: importer-config
data:
  setting.ini: "mode=full\n"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: importer
spec:
  replicas: 1
  selector:
    matchLabels: {app: importer}
  template:
    metadata:
      labels: {app: importer}
    spec:
      volumes:
        - name: config
          configMap: {name: importer-config}
      containers:
        - name: importer
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              if [ ! -f /config/settings.ini ]; then
                echo "missing /config/settings.ini"; exit 2
              fi
              echo "importing with $(cat /config/settings.ini)"
              sleep 3600
          volumeMounts:
            - {name: config, mountPath: /config}
YAML

# --- Q4: two backends and a TLS key pair --------------------------------------
kubectl apply -n r03-q4 -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports: [{containerPort: 80}]
---
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
          ports: [{name: http, containerPort: 80}]
YAML
mkdir -p "$DIR/q4"
openssl req -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN=shop.example.com" \
  -keyout "$DIR/q4/tls.key" -out "$DIR/q4/tls.crt" 2>/dev/null

kubectl wait -n r03-q4 --for=condition=Ready pod --all --timeout=180s

echo
echo "setup done -- open ckad/round-03/README.md"
