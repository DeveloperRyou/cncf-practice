#!/usr/bin/env bash
# Round 04 grader. Prints PASS/FAIL per item and the score per question.
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
resolve() { { kubectl exec -n r04-q5 dns-probe -- nslookup -timeout=3 "$1" 2>/dev/null || true; } | grep -A1 "^Name:" | grep -q "Address:\s*$2$"; }
sorted() { sed 's/^pod\///; s/[[:space:]]*$//' "$1" | grep -v '^$' | sort; }

# --- Q1 ---------------------------------------------------------------------
echo "Q1"
KC="$(dirname "$ANS")/workdir/kubeconfig"
check Q1 3 "answers/q1/contexts = all context names" \
  "diff <(sort '$ANS/q1/contexts' | grep -v '^\$') <(kubectl config get-contexts -o name --kubeconfig '$KC' | sort)"
check Q1 2 "answers/q1/current-context = prod-eu" \
  "[ \"\$(tr -d '[:space:]' < '$ANS/q1/current-context')\" = \"\$(kubectl config current-context --kubeconfig '$KC')\" ]"
check Q1 4 "answers/q1/cert = decoded client certificate of account-0027" \
  "diff <(kubectl config view --raw --kubeconfig '$KC' -o jsonpath='{.users[?(@.name==\"account-0027\")].user.client-certificate-data}' | base64 -d) '$ANS/q1/cert'"
EXP=$(node $CP 'openssl x509 -enddate -noout -in /etc/kubernetes/pki/apiserver.crt' 2>/dev/null | sed 's/^notAfter=//')
check Q1 6 "answers/q1/expiration = apiserver.crt notAfter ($EXP)" \
  "a=\$(date -d \"\$(sed 's/^notAfter=//' '$ANS/q1/expiration')\" +%s) && b=\$(date -d '$EXP' +%s) && [ \$(( a > b ? a - b : b - a )) -le 60 ]"
check Q1 5 "answers/q1/renew.sh renews only the apiserver cert" \
  "grep -qE '^[[:space:]]*kubeadm[[:space:]]+certs[[:space:]]+renew[[:space:]]+apiserver[[:space:]]*\$' '$ANS/q1/renew.sh' && ! grep -qE 'renew[[:space:]]+all|apiserver-' '$ANS/q1/renew.sh'"

# --- Q2 ---------------------------------------------------------------------
echo "Q2"
check Q2 1 "namespace cert-manager exists" "j ns cert-manager"
check Q2 4 "helm release cert-manager (chart cert-manager) deployed in cert-manager" \
  "helm list -n cert-manager -o json | jq -e 'any(.[]; .name==\"cert-manager\" and .status==\"deployed\" and (.chart|test(\"^cert-manager-\")))'"
check Q2 3 "release installed with crds.enabled=true, CRD clusterissuers present" \
  "helm get values cert-manager -n cert-manager -o json | jq -e '.crds.enabled==true' && j crd clusterissuers.cert-manager.io"
check Q2 2 "cert-manager, webhook and cainjector deployments ready" \
  "j deploy -n cert-manager | jq -e '[.items[] | select(.metadata.name|test(\"^cert-manager\")) | .status.readyReplicas==.spec.replicas] | length>=3 and all'"
check Q2 2 "workdir/cluster-issuer.yaml has crlDistributionPoints under selfSigned" \
  "grep -q 'crlDistributionPoints' '$(dirname "$ANS")/workdir/cluster-issuer.yaml' && grep -q 'http://example.com/crl' '$(dirname "$ANS")/workdir/cluster-issuer.yaml'"
check Q2 3 "ClusterIssuer selfsigned-issuer created with the field" \
  "j clusterissuer selfsigned-issuer | jq -e '.spec.selfSigned.crlDistributionPoints==[\"http://example.com/crl\"]'"

# --- Q3 ---------------------------------------------------------------------
echo "Q3"
check Q3 4 "pod api-contact: nginx:1-alpine, serviceAccount secret-reader" \
  "j pod api-contact -n r04-q3 | jq -e '.spec.serviceAccountName==\"secret-reader\" and .spec.containers[0].image==\"nginx:1-alpine\"'"
check Q3 2 "pod api-contact Running" "j pod api-contact -n r04-q3 | jq -e '.status.phase==\"Running\"'"
WANT=$(kubectl get secret -n r04-q3 -o name 2>/dev/null | sed 's#secret/##' | sort | tr '\n' ' ')
check Q3 6 "answers/q3/result.json is the SecretList of r04-q3 ($WANT)" \
  "jq -e '.kind==\"SecretList\" and .apiVersion==\"v1\"' '$ANS/q3/result.json' \
   && [ \"\$(jq -r '[.items[].metadata.name] | sort | join(\" \")' '$ANS/q3/result.json')\" = \"\$(echo $WANT)\" ]"
BE=$(kubectl get pods -n r04-q3-qos -o json 2>/dev/null | jq -r '.items[] | select(.status.qosClass=="BestEffort") | .metadata.name' | sort)
check Q3 4 "pods-terminated-first.txt lists every BestEffort pod" \
  "[ -n '$BE' ] && comm -23 <(echo '$BE') <(sorted '$ANS/q3/pods-terminated-first.txt') | wc -l | grep -qx 0"
check Q3 4 "pods-terminated-first.txt lists nothing else" \
  "[ -s '$ANS/q3/pods-terminated-first.txt' ] && comm -13 <(echo '$BE') <(sorted '$ANS/q3/pods-terminated-first.txt') | wc -l | grep -qx 0"

# --- Q4 ---------------------------------------------------------------------
echo "Q4"
NS=r04-q4-np
BK=$(kubectl get pod -n $NS -l app=backend -o name 2>/dev/null | head -1)
ip() { kubectl get pod -n $NS -l app="$1" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null; }
reach() { kubectl exec -n $NS "$BK" -- wget -q -T 3 -O /dev/null "$(ip "$1"):$2"; }
check Q4 1 "NetworkPolicy np-backend exists, selects app=backend" \
  "j netpol np-backend -n $NS | jq -e '.spec.podSelector.matchLabels.app==\"backend\"'"
check Q4 2 "backend -> db1:1111 works" "reach db1 1111"
check Q4 2 "backend -> db1 other ports blocked (80)" "! reach db1 80"
check Q4 2 "backend -> db2:2222 works" "reach db2 2222"
check Q4 2 "backend -> db2 other ports blocked (80)" "! reach db2 80"
check Q4 2 "backend -> vault blocked (80 and 3333)" "! reach vault 80 && ! reach vault 3333"
check Q4 1 "policy selects peers by app labels" \
  "j netpol np-backend -n $NS | jq -e '[.spec.egress[].to[]?.podSelector.matchLabels.app] | contains([\"db1\",\"db2\"])'"
HR="j httproute traffic-director -n r04-q4-gw"
check Q4 1 "HTTPRoute traffic-director attached to Gateway main" \
  "$HR | jq -e '.spec.parentRefs | any(.name==\"main\")'"
check Q4 1 "/desktop -> web-desktop:80" \
  "$HR | jq -e '.spec.rules | any(.[]; any(.matches[]?; .path.value==\"/desktop\") and (.backendRefs | length>0 and all(.name==\"web-desktop\" and .port==80)))'"
check Q4 1 "/mobile -> web-mobile:80" \
  "$HR | jq -e '.spec.rules | any(.[]; any(.matches[]?; .path.value==\"/mobile\") and (.backendRefs | length>0 and all(.name==\"web-mobile\" and .port==80)))'"
check Q4 3 "/auto + User-Agent=mobile in ONE match -> web-mobile; /auto never reaches web-mobile unconditionally" \
  "$HR | jq -e '(.spec.rules | any(.[]; (.backendRefs | length>0 and all(.name==\"web-mobile\")) and any(.matches[]?; .path.value==\"/auto\" and any(.headers[]?; (.name|ascii_downcase)==\"user-agent\" and .value==\"mobile\" and ((.type // \"Exact\")==\"Exact\")))))
     and (.spec.rules | all(.[]; ((.backendRefs | any(.name==\"web-mobile\")) | not) or all(.matches[]?; (.path.value!=\"/auto\" and (.path.value // \"/\")!=\"/\") or ((.headers // []) | length>0))))'"
check Q4 2 "/auto without header match -> web-desktop:80" \
  "$HR | jq -e '.spec.rules | any(.[]; (.backendRefs | length>0 and all(.name==\"web-desktop\" and .port==80)) and any(.matches[]?; .path.value==\"/auto\" and ((.headers // []) | length==0)))'"

# --- Q5 ---------------------------------------------------------------------
echo "Q5"
BKP="$ANS/q5/coredns-backup.yaml"
check Q5 3 "coredns-backup.yaml is the original ConfigMap (cluster.local, no custom-domain)" \
  "yq=\$(cat '$BKP') && echo \"\$yq\" | grep -q '^kind: ConfigMap' && echo \"\$yq\" | grep -q 'name: coredns' && echo \"\$yq\" | grep -q 'kubernetes cluster.local' && ! echo \"\$yq\" | grep -q custom-domain"
check Q5 1 "Corefile mentions custom-domain" \
  "kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -q custom-domain"
KIP=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
check Q5 4 "kubernetes.default.svc.custom-domain resolves to $KIP" "resolve kubernetes.default.svc.custom-domain $KIP"
check Q5 4 "kubernetes.default.svc.cluster.local still resolves" "resolve kubernetes.default.svc.cluster.local $KIP"
check Q5 1 "coredns deployment 2/2 ready" "j deploy coredns -n kube-system | jq -e '.status.readyReplicas==2'"
P='j pod tigers-reunite -n r04-q5'
check Q5 2 "pod tigers-reunite Running with image httpd:2-alpine" \
  "$P | jq -e '.status.phase==\"Running\" and (.spec.containers|length)==1 and .spec.containers[0].image==\"httpd:2-alpine\"'"
check Q5 2 "labels pod=container, container=pod" \
  "$P | jq -e '.metadata.labels.pod==\"container\" and .metadata.labels.container==\"pod\"'"
TN=$(kubectl get pod tigers-reunite -n r04-q5 -o jsonpath='{.spec.nodeName}' 2>/dev/null)
CID=$([ -n "$TN" ] && node "$TN" 'crictl ps -a -q --label io.kubernetes.pod.name=tigers-reunite --label io.kubernetes.pod.namespace=r04-q5' 2>/dev/null | head -1)
RTT=$([ -n "$CID" ] && node "$TN" "crictl inspect $CID" 2>/dev/null | jq -r '.info.runtimeType')
check Q5 3 "pod-container.txt line 1 = container ID of the pod's container" \
  "[ -n '$CID' ] && [ \"\$(sed -n 1p '$ANS/q5/pod-container.txt' | tr -d '[:space:]')\" = '$CID' ]"
check Q5 2 "pod-container.txt line 2 = runtimeType ($RTT)" \
  "[ -n '$RTT' ] && [ \"\$(sed -n 2p '$ANS/q5/pod-container.txt' | tr -d '[:space:]')\" = '$RTT' ]"
check Q5 3 "pod-container.log = the container's logs" \
  "[ -n '$CID' ] && [ -s '$ANS/q5/pod-container.log' ] && node $TN 'crictl logs $CID 2>&1' | head -1 | grep -qF -- \"\$(head -1 '$ANS/q5/pod-container.log')\""

# --- total ------------------------------------------------------------------
echo
total=0
for q in "${ORDER[@]}"; do
  printf '%s  %2d / %2d\n' "$q" "${GOT[$q]}" "${MAX[$q]}"
  total=$(( total + GOT[$q] ))
done
printf 'TOTAL %d / 100  (%s)\n' "$total" "$([ "$total" -ge 66 ] && echo PASS || echo FAIL)"
