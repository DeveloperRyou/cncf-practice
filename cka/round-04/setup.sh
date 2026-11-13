#!/usr/bin/env bash
# Round 04 (review) setup: recreate every r04-* namespace, cert-manager's
# leftovers and the helper files (idempotent; re-running resets the round).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../lib.sh"
WORK="$DIR/workdir"
NAMESPACES=(r04-q3 r04-q3-qos r04-q4-np r04-q4-gw r04-q5)
command -v helm >/dev/null || { echo "helm not found -- run ./scripts/install.sh" >&2; exit 1; }

# --- undo a previous run ----------------------------------------------------
helm uninstall cert-manager -n cert-manager >/dev/null 2>&1 || true
kubectl delete namespace cert-manager "${NAMESPACES[@]}" --ignore-not-found --wait=true
kubectl get crd -o name | grep -E 'cert-manager\.io' | xargs -r kubectl delete >/dev/null || true
for k in clusterrole clusterrolebinding validatingwebhookconfiguration mutatingwebhookconfiguration; do
  kubectl delete "$k" -l app.kubernetes.io/instance=cert-manager --ignore-not-found >/dev/null
done
helm repo remove jetstack >/dev/null 2>&1 || true
kubectl -n kube-system get cm coredns -o json \
  | jq '.data.Corefile |= gsub(" custom-domain"; "")' | kubectl apply -f - >/dev/null 2>&1
kubectl -n kube-system rollout restart deploy coredns >/dev/null

for ns in "${NAMESPACES[@]}"; do kubectl create namespace "$ns" >/dev/null; done
rm -rf "$WORK"; mkdir -p "$WORK"
prep_nodes
install_gateway_api

# --- Q1: a kubeconfig with several contexts and users -----------------------
KC="$WORK/kubeconfig"
for u in account-0013 account-0027 account-0042 account-0058; do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 \
    -subj "/CN=$u" -keyout "$WORK/$u.key" -out "$WORK/$u.crt" 2>/dev/null
  kubectl config set-credentials "$u" --client-certificate="$WORK/$u.crt" --client-key="$WORK/$u.key" \
    --embed-certs --kubeconfig="$KC" >/dev/null
  rm -f "$WORK/$u.key" "$WORK/$u.crt"
done
n=0
for ctx in dev-a:account-0013 qa-b:account-0027 prod-eu:account-0042 edge-ap:account-0058; do
  n=$((n+1))
  kubectl config set-cluster "cluster-$n" --server="https://cluster-$n.example.com:6443" --kubeconfig="$KC" >/dev/null
  kubectl config set-context "${ctx%%:*}" --cluster="cluster-$n" --user="${ctx##*:}" --kubeconfig="$KC" >/dev/null
done
kubectl config use-context prod-eu --kubeconfig="$KC" >/dev/null

# --- Q2: a ClusterIssuer manifest to extend ---------------------------------
cat > "$WORK/cluster-issuer.yaml" <<'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
YAML

# --- Q3: ServiceAccount + secrets; pods with assorted QoS classes -----------
kubectl create serviceaccount secret-reader -n r04-q3 >/dev/null
kubectl create role secret-reader -n r04-q3 --verb=get,list --resource=secrets >/dev/null
kubectl create rolebinding secret-reader -n r04-q3 --role=secret-reader --serviceaccount=r04-q3:secret-reader >/dev/null
kubectl create secret generic db-password -n r04-q3 --from-literal=password=s3cr3t >/dev/null
kubectl create secret generic api-key -n r04-q3 --from-literal=key=abc123 >/dev/null
kubectl create secret generic smtp-login -n r04-q3 --from-literal=user=mailer --from-literal=pass=hunter2 >/dev/null

kubectl apply -n r04-q3-qos -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: cache}
spec:
  containers:
  - {name: c, image: busybox:1.36, command: [sh, -c, "sleep 1d"]}
---
apiVersion: v1
kind: Pod
metadata: {name: report}
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: [sh, -c, "sleep 1d"]
    resources:
      requests: {cpu: 10m, memory: 16Mi}
      limits: {cpu: 50m, memory: 32Mi}
---
apiVersion: v1
kind: Pod
metadata: {name: gateway}
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: [sh, -c, "sleep 1d"]
    resources:
      requests: {cpu: 10m, memory: 16Mi}
      limits: {cpu: 10m, memory: 16Mi}
---
apiVersion: v1
kind: Pod
metadata: {name: limited}
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: [sh, -c, "sleep 1d"]
    resources:
      limits: {cpu: 20m, memory: 32Mi}
---
apiVersion: v1
kind: Pod
metadata: {name: mixed}
spec:
  containers:
  - name: main
    image: busybox:1.36
    command: [sh, -c, "sleep 1d"]
    resources:
      requests: {cpu: 10m, memory: 16Mi}
      limits: {cpu: 10m, memory: 16Mi}
  - {name: helper, image: busybox:1.36, command: [sh, -c, "sleep 1d"]}
---
apiVersion: v1
kind: Pod
metadata: {name: cpu-only}
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: [sh, -c, "sleep 1d"]
    resources:
      requests: {cpu: 10m}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: logger}
spec:
  replicas: 2
  selector: {matchLabels: {app: logger}}
  template:
    metadata: {labels: {app: logger}}
    spec:
      containers:
      - {name: c, image: busybox:1.36, command: [sh, -c, "sleep 1d"]}
YAML

# --- Q4: pods that answer on extra ports; Ingress to migrate ----------------
for spec in backend: db1:1111 db2:2222 vault:3333; do
  app="${spec%%:*}"; port="${spec##*:}"
  extra=""; [ -n "$port" ] && extra="echo 'server { listen $port; return 200 $app; }' > /etc/nginx/conf.d/extra.conf"
  kubectl apply -n r04-q4-np -f - <<YAML >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: $app}
spec:
  replicas: 1
  selector: {matchLabels: {app: $app}}
  template:
    metadata: {labels: {app: $app}}
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        command: [sh, -c]
        args:
        - |
          $extra
          exec nginx -g 'daemon off;'
YAML
done
for app in web-desktop web-mobile; do
  kubectl create deployment "$app" -n r04-q4-gw --image=nginx:1.27-alpine >/dev/null
  kubectl expose deployment "$app" -n r04-q4-gw --port=80 >/dev/null
done
kubectl apply -n r04-q4-gw -f - <<'YAML' >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: main}
spec:
  gatewayClassName: example
  listeners:
  - {name: http, port: 80, protocol: HTTP}
YAML
cat > "$WORK/ingress.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: traffic
  namespace: r04-q4-gw
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /desktop
        pathType: Prefix
        backend: {service: {name: web-desktop, port: {number: 80}}}
      - path: /mobile
        pathType: Prefix
        backend: {service: {name: web-mobile, port: {number: 80}}}
YAML

# --- Q5: grading helper pod for DNS lookups ---------------------------------
kubectl apply -n r04-q5 -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: dns-probe
  labels: {purpose: grading-helper}
spec:
  containers:
  - {name: main, image: busybox:1.36, command: [sh, -c, "sleep 1d"]}
YAML

kubectl wait -n r04-q3-qos --for=condition=Ready pod --all --timeout=180s >/dev/null
kubectl wait -n r04-q4-np --for=condition=Available deploy --all --timeout=180s >/dev/null
kubectl wait -n r04-q4-gw --for=condition=Available deploy --all --timeout=180s >/dev/null
kubectl wait -n r04-q5 --for=condition=Ready pod/dns-probe --timeout=180s >/dev/null
kubectl -n kube-system rollout status deploy coredns --timeout=120s >/dev/null

echo "round 04 ready"
