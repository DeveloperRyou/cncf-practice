#!/usr/bin/env bash
# Round 01 grader. Prints PASS/FAIL per item and the score per question.
# Read-only against the cluster; answers are read from ./answers/.
set -uo pipefail

ANS="$(cd "$(dirname "$0")" && pwd)/answers"
CLUSTER="${CLUSTER_NAME:-cncf}"
CP="$CLUSTER-control-plane"; W1="$CLUSTER-worker"; W2="$CLUSTER-worker2"
declare -A GOT MAX
ORDER=()

check() {  # check <q> <points> <description> <shell condition>
  local q=$1 pts=$2 desc=$3 cond=$4
  [[ -v MAX[$q] ]] || { MAX[$q]=0; GOT[$q]=0; ORDER+=("$q"); }
  MAX[$q]=$(( MAX[$q] + pts ))
  if ( eval "$cond" ) >/dev/null 2>&1; then
    GOT[$q]=$(( GOT[$q] + pts )); printf '  PASS  [%s] %-2s %s\n' "$q" "$pts" "$desc"
  else
    printf '  FAIL  [%s] %-2s %s\n' "$q" "$pts" "$desc"
  fi
}
j()  { kubectl get "$@" -o json 2>/dev/null; }
node() { docker exec "$1" bash -c "$2"; }
# can <verb> <resource> [extra args]: may ana (group devs) do it in r01-q1?
can() { kubectl auth can-i "$@" -n r01-q1 --as ana --as-group devs 2>/dev/null | grep -qx yes; }

# --- Q1 ---------------------------------------------------------------------
echo "Q1"
KC="kubectl --kubeconfig $ANS/q1/ana.kubeconfig"
check Q1 3 "csr ana approved, kube-apiserver-client, 1 day" \
  "j csr ana | jq -e '.spec.signerName==\"kubernetes.io/kube-apiserver-client\" and .spec.expirationSeconds==86400
     and (.status.conditions | any(.type==\"Approved\")) and (.status.certificate|length>0)'"
check Q1 3 "answers/q1/ana.crt: CN=ana, O=devs, signed by the cluster CA" \
  "openssl x509 -in '$ANS/q1/ana.crt' -noout -subject -nameopt RFC2253 | grep -qx 'subject=CN=ana,O=devs\|subject=O=devs,CN=ana' \
   && openssl verify -CAfile <(node $CP 'cat /etc/kubernetes/pki/ca.crt') '$ANS/q1/ana.crt'"
check Q1 4 "role allows pods get/list/watch/create/delete and pods/log get" \
  "can get pods && can list pods && can watch pods && can create pods && can delete pods && can get pods --subresource=log"
check Q1 2 "role allows deployments get/list" "can get deployments.apps && can list deployments.apps"
check Q1 2 "role allows nothing more (pods update, deployments create, secrets get)" \
  "j role pod-operator -n r01-q1 && ! can update pods && ! can create deployments.apps && ! can get secrets"
check Q1 2 "rolebinding pod-operator-devs -> group devs" \
  "j rolebinding pod-operator-devs -n r01-q1 | jq -e '.roleRef.name==\"pod-operator\" and .roleRef.kind==\"Role\"
     and (.subjects | any(.kind==\"Group\" and .name==\"devs\")) and (.subjects | all(.kind==\"Group\"))'"
check Q1 2 "kubeconfig: current context ana@cncf, namespace r01-q1, embedded certs" \
  "$KC config view --raw -o json | jq -e '.[\"current-context\"]==\"ana@cncf\"
     and (.contexts[] | select(.name==\"ana@cncf\") | .context.namespace==\"r01-q1\")
     and (.users[] | select(.name==\"ana\") | .user[\"client-certificate-data\"] and .user[\"client-key-data\"])'"
check Q1 2 "kubeconfig authenticates as ana/devs and lists pods" \
  "$KC auth whoami -o json | jq -e '.status.userInfo.username==\"ana\" and (.status.userInfo.groups|index(\"devs\"))' && $KC get pods"

# --- Q2 ---------------------------------------------------------------------
echo "Q2"
check Q2 6 "node $W2 Ready" \
  "j node $W2 | jq -e '.status.conditions[] | select(.type==\"Ready\") | .status==\"True\"'"
check Q2 4 "kubelet enabled and active on $W2" \
  "node $W2 'systemctl is-enabled kubelet && systemctl is-active kubelet'"
check Q2 2 "kubelet clientCAFile is the cluster CA" \
  "node $W2 'grep -q \"clientCAFile: /etc/kubernetes/pki/ca.crt\" /var/lib/kubelet/config.yaml'"
check Q2 5 "pod node-check Running on $W2, not recreated" \
  "j pod node-check -n r01-q2 | jq -e '.status.phase==\"Running\" and .spec.nodeName==\"$W2\" and (.status.containerStatuses[0].restartCount==0)'"
check Q2 3 "answers/q2/cause.txt = /var/lib/kubelet/config.yaml" \
  "grep -qx '/var/lib/kubelet/config.yaml' '$ANS/q2/cause.txt'"

# --- Q3 ---------------------------------------------------------------------
echo "Q3"
F="$ANS/q3/beacon.yaml"
check Q3 3 "beacon.yaml: Deployment beacon-probe with 3 replicas" \
  "grep -q 'name: beacon-probe' '$F' && grep -qE '^\s*replicas: 3\s*$' '$F'"
check Q3 3 "beacon.yaml: no CustomResourceDefinition" \
  "grep -q 'kind: Deployment' '$F' && ! grep -q 'kind: CustomResourceDefinition' '$F'"
check Q3 3 "helm release beacon deployed in r01-q3" \
  "helm status beacon -n r01-q3 -o json | jq -e '.info.status==\"deployed\"'"
check Q3 3 "deployment beacon-probe 2/2 ready" \
  "j deploy beacon-probe -n r01-q3 | jq -e '.spec.replicas==2 and .status.readyReplicas==2'"
check Q3 2 "crd beacons.monitoring.example.com owned by the release" \
  "j crd beacons.monitoring.example.com | jq -e '.metadata.annotations[\"meta.helm.sh/release-name\"]==\"beacon\"'"
check Q3 3 "beacon edge: interval 30s, targets api+db" \
  "j beacons.monitoring.example.com edge -n r01-q3 | jq -e '.spec.interval==\"30s\" and (.spec.targets|sort)==[\"api\",\"db\"]'"
check Q3 3 "answers/q3/interval.txt is the explain output" \
  "grep -q 'How often each target is probed' '$ANS/q3/interval.txt' && grep -q 'FIELD: *interval' '$ANS/q3/interval.txt'"

# --- Q4 ---------------------------------------------------------------------
echo "Q4"
check Q4 3 "storageclass local-logs: no-provisioner, WaitForFirstConsumer, Retain" \
  "j sc local-logs | jq -e '.provisioner==\"kubernetes.io/no-provisioner\" and .volumeBindingMode==\"WaitForFirstConsumer\" and .reclaimPolicy==\"Retain\"'"
check Q4 3 "local-logs is the only default storageclass" \
  "j sc | jq -e '[.items[] | select(.metadata.annotations[\"storageclass.kubernetes.io/is-default-class\"]==\"true\") | .metadata.name]==[\"local-logs\"]'"
check Q4 5 "logs-pvc Bound to logs-pv, requests 1Gi" \
  "j pvc logs-pvc -n r01-q4 | jq -e '.status.phase==\"Bound\" and .spec.volumeName==\"logs-pv\" and .spec.resources.requests.storage==\"1Gi\"'"
check Q4 2 "logs-pv unchanged (1Gi, RWO, Retain, local-logs)" \
  "j pvc logs-pvc -n r01-q4 | jq -e '.status.phase==\"Bound\"' && j pv logs-pv | jq -e '.spec.capacity.storage==\"1Gi\" and .spec.accessModes==[\"ReadWriteOnce\"]
     and .spec.persistentVolumeReclaimPolicy==\"Retain\" and .spec.storageClassName==\"local-logs\"'"
check Q4 3 "logs-reader mounts logs-pvc at /logs read-only" \
  "j pod logs-reader -n r01-q4 | jq -e '.spec | (.volumes[] | select(.persistentVolumeClaim.claimName==\"logs-pvc\") | .name) as \$v
     | .containers[0].volumeMounts | any(.name==\$v and .mountPath==\"/logs\" and .readOnly==true)'"
check Q4 4 "logs-reader reads /logs/seed.txt and can't write" \
  "[ \"\$(kubectl exec -n r01-q4 logs-reader -- cat /logs/seed.txt)\" = seed-ok ] && ! kubectl exec -n r01-q4 logs-reader -- touch /logs/x"

# --- Q5 ---------------------------------------------------------------------
echo "Q5"
GW='j gateway web-gw -n r01-q5'
RT='j httproute web-route -n r01-q5'
check Q5 3 "gateway web-gw: class nginx, one listener https HTTPS 443" \
  "$GW | jq -e '.spec.gatewayClassName==\"nginx\" and (.spec.listeners|length==1)
     and (.spec.listeners[0] | .name==\"https\" and .protocol==\"HTTPS\" and .port==443)'"
check Q5 2 "listener hostname web.example.com" "$GW | jq -e '.spec.listeners[0].hostname==\"web.example.com\"'"
check Q5 3 "listener terminates TLS with secret web-tls" \
  "$GW | jq -e '.spec.listeners[0].tls | (.mode // \"Terminate\")==\"Terminate\" and (.certificateRefs|length==1)
     and (.certificateRefs[0] | .name==\"web-tls\" and ((.kind // \"Secret\")==\"Secret\"))'"
check Q5 3 "httproute web-route -> web-gw, hostname web.example.com" \
  "$RT | jq -e '(.spec.parentRefs | any(.name==\"web-gw\")) and .spec.hostnames==[\"web.example.com\"]'"
check Q5 3 "rule: PathPrefix / -> web:80" \
  "$RT | jq -e '.spec.rules | any((.matches|any(.path.type==\"PathPrefix\" and .path.value==\"/\"))
     and (.backendRefs|length==1) and (.backendRefs[0] | .name==\"web\" and .port==80))'"
check Q5 3 "rule: PathPrefix /api -> api:8080" \
  "$RT | jq -e '.spec.rules | any((.matches|any(.path.type==\"PathPrefix\" and .path.value==\"/api\"))
     and (.backendRefs|length==1) and (.backendRefs[0] | .name==\"api\" and .port==8080))'"
check Q5 3 "ingress web deleted" "$GW && ! kubectl get ingress web -n r01-q5"

# --- total ------------------------------------------------------------------
echo
total=0
for q in "${ORDER[@]}"; do
  printf '%s  %2d / %2d\n' "$q" "${GOT[$q]}" "${MAX[$q]}"
  total=$(( total + GOT[$q] ))
done
printf 'TOTAL %d / 100  (%s)\n' "$total" "$([ "$total" -ge 66 ] && echo PASS || echo FAIL)"
