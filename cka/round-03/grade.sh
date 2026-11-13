#!/usr/bin/env bash
# Round 03 grader. Prints PASS/FAIL per item and the score per question.
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
SA=system:serviceaccount:r03-q5:deployer
can() { kubectl auth can-i "$@" --as "$SA" 2>/dev/null | grep -qx yes; }

# --- Q1 ---------------------------------------------------------------------
echo "Q1"
check Q1 3 "kube-scheduler manifest uses scheduler.conf again" \
  "node $CP 'grep -qE -- \"^ *- --kubeconfig=/etc/kubernetes/scheduler.conf\\\$\" /etc/kubernetes/manifests/kube-scheduler.yaml'"
check Q1 4 "kube-scheduler running" \
  "node $CP 'crictl ps --name kube-scheduler --state running -q | grep -q .' \
   && j pod kube-scheduler-$CP -n kube-system | jq -e '.status.conditions[] | select(.type==\"Ready\") | .status==\"True\"'"
check Q1 5 "deployment queue 2/2 ready, unchanged" \
  "j deploy queue -n r03-q1 | jq -e '.status.readyReplicas==2 and .spec.replicas==2 and .metadata.generation==1'"
SVC_CIDR=$(node $CP "grep -oP '(?<=--service-cluster-ip-range=)\S+' /etc/kubernetes/manifests/kube-apiserver.yaml" 2>/dev/null)
POD_CIDR=$(node $CP "grep -oP '(?<=--cluster-cidr=)\S+' /etc/kubernetes/manifests/kube-controller-manager.yaml" 2>/dev/null)
check Q1 4 "answers/q1/service-cidr.txt = $SVC_CIDR" "[ -n '$SVC_CIDR' ] && grep -qx '$SVC_CIDR' '$ANS/q1/service-cidr.txt'"
check Q1 4 "answers/q1/pod-cidr.txt = $POD_CIDR"     "[ -n '$POD_CIDR' ] && grep -qx '$POD_CIDR' '$ANS/q1/pod-cidr.txt'"

# --- Q2 ---------------------------------------------------------------------
echo "Q2"
MP='j pod health-probe-'$W2' -n r03-q2'
check Q2 5 "mirror pod health-probe-$W2 Running in r03-q2" \
  "$MP | jq -e '.status.phase==\"Running\" and .metadata.annotations[\"kubernetes.io/config.source\"]==\"file\"'"
check Q2 3 "pod spec: nginx:1.27-alpine, app=health-probe, port 80, cpu 10m" \
  "$MP | jq -e '.metadata.labels.app==\"health-probe\" and (.spec.containers[0] | .image==\"nginx:1.27-alpine\"
     and (.ports|any(.containerPort==80)) and .resources.requests.cpu==\"10m\")'"
check Q2 2 "manifest in /etc/kubernetes/static, kubelet config unchanged" \
  "node $W2 'grep -qx \"staticPodPath: /etc/kubernetes/static\" /var/lib/kubelet/config.yaml && grep -ls health-probe /etc/kubernetes/static/* >/dev/null'"
check Q2 3 "answers/q2/static-path.txt = /etc/kubernetes/static" \
  "grep -qxE '/etc/kubernetes/static/?' '$ANS/q2/static-path.txt'"
RT=$(kubectl get node $W2 -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}' 2>/dev/null)
check Q2 4 "answers/q2/runtime.txt = $RT" "[ -n '$RT' ] && grep -qx '$RT' '$ANS/q2/runtime.txt'"
check Q2 3 "pod health-probe-$W2 is a static pod (no API-created copy)" \
  "$MP | jq -e '.metadata.ownerReferences | any(.kind==\"Node\")' && [ \"\$(kubectl get pods -n r03-q2 --no-headers | wc -l)\" = 1 ]"

# --- Q3 ---------------------------------------------------------------------
echo "Q3"
DS='j ds log-agent -n r03-q3'
S="$DS | jq -e '.spec.template.spec"
check Q3 4 "log-agent ready on all 3 nodes" \
  "$DS | jq -e '.status.desiredNumberScheduled==3 and .status.numberReady==3'"
check Q3 5 "shipper is a native sidecar (initContainer, restartPolicy Always, tail -F)" \
  "$S | .initContainers // [] | any(.name==\"shipper\" and .image==\"busybox:1.36\" and .restartPolicy==\"Always\"
     and ((.command // []) + (.args // []) | join(\" \") | test(\"tail -F /var/log/app/app.log\")))'"
check Q3 3 "emptyDir logs at /var/log/app in app and shipper" \
  "$S | (.volumes | any(.name==\"logs\" and .emptyDir)) and
     ([.initContainers[]?, .containers[]] | map(select(.name==\"app\" or .name==\"shipper\")) | length==2
       and all(any(.volumeMounts[]?; .name==\"logs\" and .mountPath==\"/var/log/app\")))'"
check Q3 2 "both request 10m cpu / 16Mi memory" \
  "$S | [.initContainers[]?, .containers[]] | map(select(.name==\"app\" or .name==\"shipper\")) | length==2
     and all(.resources.requests.cpu==\"10m\" and .resources.requests.memory==\"16Mi\")'"
check Q3 3 "rolling update maxSurge 1, maxUnavailable 0" \
  "$DS | jq -e '.spec.updateStrategy | .type==\"RollingUpdate\" and .rollingUpdate.maxSurge==1 and .rollingUpdate.maxUnavailable==0'"
check Q3 3 "shipper prints the date lines written by app" \
  "P=\$(kubectl get pods -n r03-q3 -o name | head -1) && kubectl logs -n r03-q3 \$P -c shipper --tail=5 | grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}'"

# --- Q4 ---------------------------------------------------------------------
echo "Q4"
IN='j ingress shop -n r03-q4'
check Q4 3 "service shop: port 80 -> named port http" \
  "j svc shop -n r03-q4 | jq -e '(.spec.ports|length==1) and .spec.ports[0].port==80 and .spec.ports[0].targetPort==\"http\"'"
check Q4 4 "service shop has the 2 shop pods as ready endpoints (port 80)" \
  "j endpointslices -n r03-q4 -l kubernetes.io/service-name=shop | jq -e '([.items[].endpoints[]? | select(.conditions.ready)] | length==2)
     and (.items | all(.ports | any(.port==80)))' \
   && j deploy shop -n r03-q4 | jq -e '.metadata.generation==1'"
check Q4 3 "secret shop-tls (kubernetes.io/tls) holds workdir/shop.crt" \
  "j secret shop-tls -n r03-q4 | jq -e '.type==\"kubernetes.io/tls\"' \
   && diff <(kubectl get secret shop-tls -n r03-q4 -o jsonpath='{.data.tls\.crt}' | base64 -d) '$(dirname "$ANS")/workdir/shop.crt'"
check Q4 4 "ingress shop: class nginx, host shop.example.com, tls shop-tls" \
  "$IN | jq -e '.spec.ingressClassName==\"nginx\" and (.spec.rules|length==1) and .spec.rules[0].host==\"shop.example.com\"
     and (.spec.tls | any(.secretName==\"shop-tls\" and (.hosts|index(\"shop.example.com\"))))'"
check Q4 3 "ingress /api Prefix -> shop:80" \
  "$IN | jq -e '.spec.rules[0].http.paths | any(.path==\"/api\" and .pathType==\"Prefix\" and .backend.service.name==\"shop\" and .backend.service.port.number==80)'"
check Q4 3 "ingress / Prefix -> static:80" \
  "$IN | jq -e '.spec.rules[0].http.paths | any(.path==\"/\" and .pathType==\"Prefix\" and .backend.service.name==\"static\" and .backend.service.port.number==80)'"

# --- Q5 ---------------------------------------------------------------------
echo "Q5"
check Q5 3 "deployer manages deployments in r03-q5 and r03-q5-staging" \
  "j rolebinding deployer -n r03-q5 && for n in r03-q5 r03-q5-staging; do for v in get list watch create update patch delete; do can \$v deployments.apps -n \$n || exit 1; done; done"
check Q5 2 "deployer scales deployments (scale subresource)" \
  "j rolebinding deployer -n r03-q5 && can update deployments.apps --subresource=scale -n r03-q5 && can patch deployments.apps --subresource=scale -n r03-q5-staging"
check Q5 3 "rolebinding deployer in both namespaces -> ClusterRole deploy-manager" \
  "for n in r03-q5 r03-q5-staging; do j rolebinding deployer -n \$n | jq -e '.roleRef.kind==\"ClusterRole\" and .roleRef.name==\"deploy-manager\"
     and (.subjects | any(.kind==\"ServiceAccount\" and .name==\"deployer\" and .namespace==\"r03-q5\"))' || exit 1; done"
check Q5 3 "deployer lists/gets nodes via deployer-node-reader" \
  "can list nodes && can get nodes && j clusterrolebinding deployer-node-reader | jq -e '.roleRef.name==\"node-reader\"'"
check Q5 3 "no deployments outside the two namespaces" \
  "j rolebinding deployer -n r03-q5 && ! can create deployments.apps -n default && ! can list deployments.apps -A"
check Q5 3 "no secrets, pods or services anywhere" \
  "j rolebinding deployer -n r03-q5 && ! can get secrets -n r03-q5 && ! can create pods -n r03-q5 && ! can delete services -n r03-q5-staging"
check Q5 3 "no write on nodes, no other ClusterRoleBinding for deployer" \
  "j clusterrolebinding deployer-node-reader && ! can delete nodes && ! can patch nodes \
   && [ \"\$(kubectl get clusterrolebinding -o json | jq '[.items[] | select(.subjects[]? | .kind==\"ServiceAccount\" and .name==\"deployer\" and .namespace==\"r03-q5\")] | length')\" = 1 ]"
# --- total ------------------------------------------------------------------
echo
total=0
for q in "${ORDER[@]}"; do
  printf '%s  %2d / %2d\n' "$q" "${GOT[$q]}" "${MAX[$q]}"
  total=$(( total + GOT[$q] ))
done
printf 'TOTAL %d / 100  (%s)\n' "$total" "$([ "$total" -ge 66 ] && echo PASS || echo FAIL)"
