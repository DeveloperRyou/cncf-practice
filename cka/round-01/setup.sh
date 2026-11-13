#!/usr/bin/env bash
# Round 01 setup: recreate every r01-* namespace and the node-level state
# (idempotent; re-running resets the round).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"
command -v helm >/dev/null || { echo "helm not found -- run ./scripts/install.sh" >&2; exit 1; }
WORK="$DIR/workdir"
NAMESPACES=(r01-q1 r01-q2 r01-q3 r01-q4 r01-q5)

helm uninstall beacon -n r01-q3 >/dev/null 2>&1 || true
kubectl delete namespace "${NAMESPACES[@]}" --ignore-not-found --wait=true
kubectl delete csr ana --ignore-not-found
kubectl delete crd beacons.monitoring.example.com --ignore-not-found
kubectl delete pv logs-pv --ignore-not-found
kubectl delete storageclass local-logs --ignore-not-found
kubectl annotate storageclass standard storageclass.kubernetes.io/is-default-class=true --overwrite >/dev/null
for ns in "${NAMESPACES[@]}"; do kubectl create namespace "$ns"; done
rm -rf "$WORK"; mkdir -p "$WORK"
prep_nodes

# --- Q2: kubelet on worker2 won't start, and won't come back after a reboot -
# KNOWN ISSUE: node-check is a bare pod, so once worker2 has been NotReady for
# ~5 min (default 300s not-ready toleration) the taint manager evicts it and
# nothing recreates it, which makes Q2.2 ("Running, don't recreate") unmeetable.
# Left as is for the round already in progress; fix (tolerationSeconds on the
# pod) before reusing this round.
node "$W2" 'sed -i "s#clientCAFile: /etc/kubernetes/pki/ca.crt#clientCAFile: /etc/kubernetes/pki/client-ca.crt#" /var/lib/kubelet/config.yaml
  systemctl disable --now kubelet 2>/dev/null'
kubectl apply -n r01-q2 -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: node-check
spec:
  nodeName: $W2
  containers:
  - name: main
    image: busybox:1.36
    command: ["sh", "-c", "sleep 1d"]
YAML

# --- Q3: a local chart whose templates also ship the CRD --------------------
C="$WORK/charts/beacon"
mkdir -p "$C/templates"
cat > "$C/Chart.yaml" <<'YAML'
apiVersion: v2
name: beacon
description: Synthetic monitoring probes
version: 1.4.0
appVersion: "1.27"
YAML
cat > "$C/values.yaml" <<'YAML'
replicaCount: 1
image:
  repository: nginx
  tag: "1.27-alpine"
crds:
  # Render the Beacon CustomResourceDefinition with the release.
  install: true
service:
  port: 80
YAML
cat > "$C/templates/crd.yaml" <<'YAML'
{{- if .Values.crds.install }}
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: beacons.monitoring.example.com
  annotations:
    helm.sh/resource-policy: keep
spec:
  group: monitoring.example.com
  names: {kind: Beacon, plural: beacons, singular: beacon, shortNames: [bcn]}
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [interval]
            properties:
              interval:
                type: string
                description: How often each target is probed, as a Go duration such as 30s or 2m. Probes never overlap.
              targets:
                type: array
                description: Names of the Services to probe in the Beacon's namespace.
                items: {type: string}
{{- end }}
YAML
cat > "$C/templates/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}-probe
  labels: {app: {{ .Release.Name }}-probe}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels: {app: {{ .Release.Name }}-probe}
  template:
    metadata:
      labels: {app: {{ .Release.Name }}-probe}
    spec:
      containers:
      - name: probe
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        ports: [{containerPort: 80}]
YAML
cat > "$C/templates/service.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-probe
spec:
  selector: {app: {{ .Release.Name }}-probe}
  ports: [{port: {{ .Values.service.port }}, targetPort: 80}]
YAML

# --- Q4: a local PV on worker and a PVC that can't bind to it --------------
node "$W1" 'mkdir -p /mnt/logs && echo seed-ok > /mnt/logs/seed.txt'
kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: logs-pv
spec:
  capacity: {storage: 1Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-logs
  local: {path: /mnt/logs}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: kubernetes.io/hostname, operator: In, values: [$W1]}
YAML
kubectl apply -n r01-q4 -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: logs-pvc
spec:
  storageClassName: local-log
  accessModes: [ReadWriteMany]
  resources:
    requests: {storage: 2Gi}
YAML

# --- Q5: an Ingress to move to Gateway API ----------------------------------
install_gateway_api
kubectl apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: nginx
spec:
  controllerName: gateway.nginx.org/nginx-gateway-controller
YAML
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=web.example.com" \
  -keyout "$WORK/web.key" -out "$WORK/web.crt" 2>/dev/null
kubectl create secret tls web-tls -n r01-q5 --cert="$WORK/web.crt" --key="$WORK/web.key" >/dev/null
for app in web api; do
  kubectl create deployment "$app" -n r01-q5 --image=nginx:1.27-alpine >/dev/null
done
kubectl expose deployment web -n r01-q5 --port=80 >/dev/null
kubectl expose deployment api -n r01-q5 --port=8080 --target-port=80 >/dev/null
kubectl apply -n r01-q5 -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
spec:
  tls:
  - hosts: [web.example.com]
    secretName: web-tls
  rules:
  - host: web.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: {service: {name: web, port: {number: 80}}}
      - path: /api
        pathType: Prefix
        backend: {service: {name: api, port: {number: 8080}}}
YAML

echo "round 01 ready"
