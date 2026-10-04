#!/usr/bin/env bash
# Round 04 grader. Prints PASS/FAIL per item and the score per question.
# Read-only against the cluster; answers are read from ./answers/.
set -uo pipefail

ANS="$(cd "$(dirname "$0")" && pwd)/answers"
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
# probe <ns> <pod> <url>: does an HTTP GET from that pod succeed within 3s?
probe() { kubectl exec -n "$1" "$2" -- wget -q -T 3 -O /dev/null "$3"; }
# ready_eps <ns> <svc>: number of ready endpoints behind a Service
ready_eps() {
  j endpointslices -n "$1" -l "kubernetes.io/service-name=$2" \
    | jq '[.items[].endpoints[]? | select(.conditions.ready)] | length'
}

# --- Q1 ---------------------------------------------------------------------
echo "Q1"
AS=system:serviceaccount:r04-q1:deployer
can() { [ "$(kubectl auth can-i "$@" -n r04-q1 --as=$AS 2>/dev/null)" = yes ]; }
D='j deploy app -n r04-q1'
check Q1 2 "serviceaccount deployer" "j sa deployer -n r04-q1 | jq -e '.metadata.name'"
check Q1 4 "deployer can get/list/patch/update deployments" \
  "can get deployments.apps && can list deployments.apps && can patch deployments.apps && can update deployments.apps"
check Q1 3 "deployer can get/list pods" "can get pods && can list pods"
check Q1 4 "deployer cannot delete/create deployments, delete pods, read secrets" \
  "can patch deployments.apps && ! can delete deployments.apps && ! can create deployments.apps && ! can delete pods && ! can get secrets"
check Q1 4 "rolebinding deployer: Role deployer -> SA deployer" \
  "j rolebinding deployer -n r04-q1 | jq -e '.roleRef.kind==\"Role\" and .roleRef.name==\"deployer\"
     and (.subjects | any(.kind==\"ServiceAccount\" and .name==\"deployer\" and (.namespace // \"r04-q1\")==\"r04-q1\"))'"
check Q1 3 "answers/q1/can-patch.txt = yes, can-delete.txt = no" \
  "[ \"\$(tr -d '[:space:]' < '$ANS/q1/can-patch.txt')\" = yes ] && [ \"\$(tr -d '[:space:]' < '$ANS/q1/can-delete.txt')\" = no ]"
check Q1 3 "app pod template uses serviceAccountName deployer" \
  "$D | jq -e '.spec.template.spec.serviceAccountName==\"deployer\"'"
check Q1 4 "app pod template automountServiceAccountToken=false, no token in pod" \
  "$D | jq -e '.spec.template.spec.automountServiceAccountToken==false' \
   && ! kubectl exec -n r04-q1 deploy/app -- ls /var/run/secrets/kubernetes.io/serviceaccount/token"
check Q1 3 "app 2/2 updated and ready" \
  "$D | jq -e '.spec.template.spec.serviceAccountName==\"deployer\" and .status.readyReplicas==2 and .status.updatedReplicas==2 and .status.replicas==2'"

# --- Q2 ---------------------------------------------------------------------
echo "Q2"
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
W='j pod writer -n r04-q2'
R='j pod reader -n r04-q2'
MOUNTS='.spec.volumes[]? | select(.persistentVolumeClaim.claimName=="data") | .name'
check Q2 5 "pvc data: standard, RWO, 100Mi, Bound" \
  "j pvc data -n r04-q2 | jq -e '.spec.storageClassName==\"standard\" and .spec.accessModes==[\"ReadWriteOnce\"]
     and .spec.resources.requests.storage==\"100Mi\" and .status.phase==\"Bound\"'"
check Q2 3 "writer mounts pvc data at /data" \
  "$W | jq -e '[$MOUNTS] as \$v | .spec.containers[0].volumeMounts | any(.mountPath==\"/data\" and (.name|IN(\$v[])))'"
check Q2 5 "MY_POD / MY_NODE from the Downward API" \
  "$W | jq -e '.spec.containers[0].env // [] | any(.name==\"MY_POD\" and .valueFrom.fieldRef.fieldPath==\"metadata.name\")
     and any(.name==\"MY_NODE\" and .valueFrom.fieldRef.fieldPath==\"spec.nodeName\")'"
check Q2 3 "writer and reader Running (busybox:1.36)" \
  "$W | jq -e '.status.phase==\"Running\" and .spec.containers[0].image==\"busybox:1.36\"' \
   && $R | jq -e '.status.phase==\"Running\" and .spec.containers[0].image==\"busybox:1.36\"'"
check Q2 4 "reader mounts pvc data read-only at /data" \
  "$R | jq -e '[$MOUNTS] as \$v | .spec.containers[0].volumeMounts | any(.mountPath==\"/data\" and .readOnly==true and (.name|IN(\$v[])))' \
   && ! kubectl exec -n r04-q2 reader -- touch /data/probe"
check Q2 5 "reader sees 'writer on <node>' in /data/owners.txt" \
  "[ -n '$NODE' ] && kubectl exec -n r04-q2 reader -- cat /data/owners.txt | grep -x 'writer on $NODE' >/dev/null"

# --- Q3 ---------------------------------------------------------------------
echo "Q3"
Q3DIR="$ANS/../q3"
D='j deploy prod-web -n r04-q3'
check Q3 3 "overlay overlays/prod builds" \
  "kubectl kustomize '$Q3DIR/overlays/prod' | grep -q 'namespace: r04-q3'"
check Q3 2 "base unchanged" \
  "[ -f '$Q3DIR/overlays/prod/kustomization.yaml' ] && grep -q 'image: nginx:1.26-alpine' '$Q3DIR/base/deployment.yaml' && grep -q 'replicas: 1' '$Q3DIR/base/deployment.yaml' \
   && ! grep -rq 'namespace:' '$Q3DIR/base'"
check Q3 4 "deployment prod-web 3/3 ready" "$D | jq -e '.spec.replicas==3 and .status.readyReplicas==3'"
check Q3 3 "prod-web image nginx:1.27-alpine" "$D | jq -e '.spec.template.spec.containers[0].image==\"nginx:1.27-alpine\"'"
check Q3 4 "label env=prod on deployment, pod template and service" \
  "$D | jq -e '.metadata.labels.env==\"prod\" and .spec.template.metadata.labels.env==\"prod\"' \
   && j svc prod-web -n r04-q3 | jq -e '.metadata.labels.env==\"prod\"'"
check Q3 4 "service prod-web has 3 ready endpoints" "[ \"\$(ready_eps r04-q3 prod-web)\" = 3 ]"

# --- Q4 ---------------------------------------------------------------------
echo "Q4"
URL=http://api.r04-q4.svc.cluster.local
check Q4 3 "default-deny unchanged" \
  "probe r04-q4 frontend $URL && j networkpolicy default-deny -n r04-q4 | jq -e '.spec.podSelector=={} and .spec.policyTypes==[\"Ingress\"] and (.spec.ingress // [] | length==0)'"
check Q4 4 "allow-api selects app=api, TCP 80 only" \
  "j networkpolicy allow-api -n r04-q4 | jq -e '.spec.podSelector.matchLabels==({app:\"api\"})
     and (.spec.ingress | length>0 and all(.ports == [{protocol:\"TCP\",port:80}]))'"
check Q4 5 "r04-q4/frontend -> api allowed" "probe r04-q4 frontend $URL"
check Q4 5 "r04-q4-mon/prober -> api allowed" "probe r04-q4-mon prober $URL"
check Q4 4 "r04-q4/intruder -> api blocked" "probe r04-q4 frontend $URL && ! probe r04-q4 intruder $URL"
check Q4 4 "r04-q4-other/frontend -> api blocked" "probe r04-q4 frontend $URL && ! probe r04-q4-other frontend $URL"

# --- total ------------------------------------------------------------------
echo
total=0
for q in "${ORDER[@]}"; do
  printf '%s  %2d / %2d\n' "$q" "${GOT[$q]}" "${MAX[$q]}"
  total=$(( total + GOT[$q] ))
done
printf 'TOTAL %d / 100  (%s)\n' "$total" "$([ "$total" -ge 66 ] && echo PASS || echo FAIL)"
