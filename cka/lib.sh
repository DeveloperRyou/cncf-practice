# Shared helpers for cka/round-*/setup.sh (sourced, not run).
# kind node names follow the cluster name: cncf-control-plane, cncf-worker,
# cncf-worker2 (CLUSTER_NAME=scratch gives scratch-*).
CLUSTER="${CLUSTER_NAME:-cncf}"
CP="$CLUSTER-control-plane"
W1="$CLUSTER-worker"
W2="$CLUSTER-worker2"
NODES=("$CP" "$W1" "$W2")

GATEWAY_API_VERSION=v1.3.0
METRICS_SERVER_VERSION=v0.7.2

node() { docker exec -i "$1" bash -c "$2"; }  # node <name> <script>

[ "$(kind get nodes --name "$CLUSTER" 2>/dev/null | wc -l)" = 3 ] \
  || { echo "CKA rounds need the 3-node cluster: ./scripts/down.sh && KIND_CONFIG=kind/cka.yaml ./scripts/up.sh" >&2; exit 1; }

# kind nodes ship without an editor; the exam nodes have vim.
prep_nodes() {
  for n in "${NODES[@]}"; do
    node "$n" 'command -v vim >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vim-tiny \
      && ln -sf /usr/bin/vim.tiny /usr/local/bin/vim; } >/dev/null 2>&1' &
  done
  wait
}

install_gateway_api() {
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null
  kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io --timeout=60s >/dev/null
}

# kind's kubelets serve self-signed certs, hence --kubelet-insecure-tls.
install_metrics_server() {
  kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml" >/dev/null
  kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q insecure-tls \
    || kubectl -n kube-system patch deploy metrics-server --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
  kubectl -n kube-system rollout status deploy metrics-server --timeout=180s >/dev/null
}
