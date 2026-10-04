#!/usr/bin/env bash
# Round 02 grader. Prints PASS/FAIL per item and the score per question.
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
CJ='j cronjob backup -n r02-q1'
JT="$CJ | jq -e '.spec.jobTemplate.spec"
C="$JT.template.spec.containers[0]"
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
check Q1 2 "schedule '30 2 * * *'"       "$CJ | jq -e '.spec.schedule==\"30 2 * * *\"'"
check Q1 2 "concurrencyPolicy=Forbid"    "$CJ | jq -e '.spec.concurrencyPolicy==\"Forbid\"'"
check Q1 2 "history limits 2 successful / 1 failed" \
  "$CJ | jq -e '.spec.successfulJobsHistoryLimit==2 and .spec.failedJobsHistoryLimit==1'"
check Q1 2 "job activeDeadlineSeconds=40" "$JT.activeDeadlineSeconds==40'"
check Q1 1 "restartPolicy OnFailure, container backup (busybox:1.36)" \
  "$JT.template.spec.restartPolicy==\"OnFailure\"' && $C | .name==\"backup\" and .image==\"busybox:1.36\"'"
check Q1 3 "NODE_NAME from fieldRef spec.nodeName" \
  "$C.env[]? | select(.name==\"NODE_NAME\") | .valueFrom.fieldRef.fieldPath==\"spec.nodeName\"'"
check Q1 3 "job backup-manual created from cronjob and succeeded" \
  "j job backup-manual -n r02-q1 | jq -e '(.metadata.ownerReferences // [] | any(.kind==\"CronJob\" and .name==\"backup\")) and .status.succeeded>=1'"
check Q1 3 "answers/q1/backup.log has 'backup done on <node>'" \
  "[ -n '$NODE' ] && grep -qx 'backup done on $NODE' '$ANS/q1/backup.log'"

# --- Q2 ---------------------------------------------------------------------
echo "Q2"
V2='j deploy shop-v2 -n r02-q2'
C="$V2 | jq -e '.spec.template.spec.containers[0]"
check Q2 4 "shop-v2: 1 replica, nginx:1.27-alpine, labels app=shop,version=v2" \
  "$V2 | jq -e '.spec.replicas==1 and .spec.template.metadata.labels.app==\"shop\" and .spec.template.metadata.labels.version==\"v2\"' \
   && $C | .name==\"nginx\" and .image==\"nginx:1.27-alpine\"'"
check Q2 4 "shop-v2 pod serves html-v2 ('shop v2')" \
  "[ \"\$(kubectl exec -n r02-q2 deploy/shop-v2 -- wget -qO- -T 3 http://localhost/)\" = 'shop v2' ]"
check Q2 2 "shop-v2 readinessProbe httpGet / on port 80" \
  "$C | .readinessProbe.httpGet | .path==\"/\" and .port==80'"
check Q2 3 "shop-v1 scaled to 3, all ready" \
  "j deploy shop-v1 -n r02-q2 | jq -e '.spec.replicas==3 and .status.readyReplicas==3'"
check Q2 3 "service shop selects app=shop (no version)" \
  "j svc shop -n r02-q2 | jq -e '.spec.selector==({app:\"shop\"}) and .spec.type==\"ClusterIP\" and .spec.ports[0].port==80'"
check Q2 4 "service shop has 4 ready endpoints (3 v1 + 1 v2)" \
  "j endpointslices -n r02-q2 -l kubernetes.io/service-name=shop | jq -e '[.items[].endpoints[]? | select(.conditions.ready) | .targetRef.name]
     | length==4 and (map(select(startswith(\"shop-v2-\"))) | length==1)'"

# --- Q3 ---------------------------------------------------------------------
echo "Q3"
W='j deploy worker -n r02-q3'
CW='j deploy cache-warmer -n r02-q3'
check Q3 4 "worker 2/2 ready" \
  "$W | jq -e '.spec.replicas==2 and .status.readyReplicas==2 and .status.updatedReplicas==2'"
check Q3 3 "worker still busybox:1.36 and logs 'working'" \
  "$W | jq -e '.spec.template.spec.containers[0].image==\"busybox:1.36\"' && kubectl logs -n r02-q3 deploy/worker | grep -x working >/dev/null"
check Q3 5 "answers/q3/reason.txt = OOMKilled" "[ \"\$(tr -d '[:space:]' < '$ANS/q3/reason.txt')\" = OOMKilled ]"
check Q3 2 "cache-warmer memory limit 128Mi, request unchanged (16Mi)" \
  "$CW | jq -e '.spec.template.spec.containers[0].resources | .limits.memory==\"128Mi\" and .requests.memory==\"16Mi\"'"
check Q3 3 "cache-warmer pod running with 0 restarts" \
  "$CW | jq -e '.status.readyReplicas==1 and .status.updatedReplicas==1' \
   && j pods -n r02-q3 -l app=cache-warmer | jq -e '[.items[] | select(.metadata.deletionTimestamp|not)] | length==1 and all(.status.containerStatuses[0].restartCount==0)'"

# --- Q4 ---------------------------------------------------------------------
echo "Q4"
AS=system:serviceaccount:r02-q4:pod-reader
can() { [ "$(kubectl auth can-i "$@" -n r02-q4 --as=$AS 2>/dev/null)" = yes ]; }
P='j pod audit -n r02-q4'
X='kubectl exec -n r02-q4 audit --'
check Q4 4 "limitrange container-defaults: requests 100m/64Mi, limits 200m/128Mi" \
  "j limitrange container-defaults -n r02-q4 | jq -e '.spec.limits | any(.type==\"Container\"
     and .defaultRequest.cpu==\"100m\" and .defaultRequest.memory==\"64Mi\"
     and .default.cpu==\"200m\" and .default.memory==\"128Mi\")'"
check Q4 3 "report 2/2 ready, no resources in spec, quota unchanged" \
  "j deploy report -n r02-q4 | jq -e '.status.readyReplicas==2 and (.spec.template.spec.containers[0].resources // {} | length==0)' \
   && j resourcequota compute-quota -n r02-q4 | jq -e '.spec.hard | .pods==\"6\" and .[\"requests.cpu\"]==\"1\" and .[\"limits.memory\"]==\"1Gi\"'"
check Q4 1 "serviceaccount pod-reader" "j sa pod-reader -n r02-q4 | jq -e '.metadata.name'"
check Q4 2 "pod-reader can get/list/watch pods and get pods/log" \
  "can get pods && can list pods && can watch pods && can get pods --subresource=log"
check Q4 2 "pod-reader cannot delete/create pods or read secrets" \
  "can list pods && ! can delete pods && ! can create pods && ! can get secrets"
check Q4 3 "rolebinding pod-reader: Role pod-reader -> SA pod-reader" \
  "j rolebinding pod-reader -n r02-q4 | jq -e '.roleRef.kind==\"Role\" and .roleRef.name==\"pod-reader\"
     and (.subjects | any(.kind==\"ServiceAccount\" and .name==\"pod-reader\" and (.namespace // \"r02-q4\")==\"r02-q4\"))'"
check Q4 2 "answers/q4/can-list.txt = yes, can-delete.txt = no" \
  "[ \"\$(tr -d '[:space:]' < '$ANS/q4/can-list.txt')\" = yes ] && [ \"\$(tr -d '[:space:]' < '$ANS/q4/can-delete.txt')\" = no ]"
check Q4 2 "pod audit Running as pod-reader" \
  "$P | jq -e '.status.phase==\"Running\" and .spec.serviceAccountName==\"pod-reader\" and .spec.containers[0].image==\"busybox:1.36\"'"
check Q4 3 "POD_NAME / POD_NAMESPACE from the Downward API" \
  "$P | jq -e '.spec.containers[0].env // [] | (any(.name==\"POD_NAME\" and .valueFrom.fieldRef.fieldPath==\"metadata.name\")
     and any(.name==\"POD_NAMESPACE\" and .valueFrom.fieldRef.fieldPath==\"metadata.namespace\"))' \
   && [ \"\$($X printenv POD_NAME)\" = audit ] && [ \"\$($X printenv POD_NAMESPACE)\" = r02-q4 ]"
check Q4 3 "secret api-token at /etc/token, readOnly, mode 0400" \
  "$P | jq -e '.spec.containers[0].volumeMounts | any(.mountPath==\"/etc/token\" and .readOnly==true)' \
   && [ \"\$($X cat /etc/token/token)\" = c2VjcmV0LXRva2Vu ] && [ \"\$($X stat -L -c %a /etc/token/token)\" = 400 ]"

# --- Q5 ---------------------------------------------------------------------
echo "Q5"
ING='j ingress web -n r02-q5'
NP='j networkpolicy client-egress -n r02-q5'
check Q5 3 "svc-a ClusterIP 8080 -> 80 with 2 ready endpoints" \
  "j svc svc-a -n r02-q5 | jq -e '.spec.type==\"ClusterIP\" and .spec.ports[0].port==8080 and .spec.ports[0].targetPort==80' \
   && [ \"\$(ready_eps r02-q5 svc-a)\" = 2 ]"
check Q5 3 "svc-b NodePort 80 -> 80, nodePort 30080, 2 ready endpoints" \
  "j svc svc-b -n r02-q5 | jq -e '.spec.type==\"NodePort\" and .spec.ports[0].port==80 and .spec.ports[0].targetPort==80 and .spec.ports[0].nodePort==30080' \
   && [ \"\$(ready_eps r02-q5 svc-b)\" = 2 ]"
check Q5 1 "ingress web: class nginx, host shop.local" \
  "$ING | jq -e '.spec.ingressClassName==\"nginx\" and (.spec.rules | length==1) and .spec.rules[0].host==\"shop.local\"'"
check Q5 2 "ingress /a Prefix -> svc-a:8080" \
  "$ING | jq -e '.spec.rules[0].http.paths | any(.path==\"/a\" and .pathType==\"Prefix\" and .backend.service.name==\"svc-a\" and .backend.service.port.number==8080)'"
check Q5 2 "ingress /b Prefix -> svc-b:80" \
  "$ING | jq -e '.spec.rules[0].http.paths | any(.path==\"/b\" and .pathType==\"Prefix\" and .backend.service.name==\"svc-b\" and .backend.service.port.number==80)'"
check Q5 2 "networkpolicy client-egress selects role=client, Egress" \
  "$NP | jq -e '.spec.podSelector.matchLabels==({role:\"client\"}) and (.spec.policyTypes | index(\"Egress\"))'"
check Q5 3 "client -> svc-a:8080 by name allowed" "probe r02-q5 client http://svc-a:8080"
check Q5 2 "client -> svc-b blocked" "probe r02-q5 client http://svc-a:8080 && ! probe r02-q5 client http://svc-b"
check Q5 2 "other -> svc-b still allowed" "j networkpolicy client-egress -n r02-q5 && probe r02-q5 other http://svc-b"

# --- total ------------------------------------------------------------------
echo
total=0
for q in "${ORDER[@]}"; do
  printf '%s  %2d / %2d\n' "$q" "${GOT[$q]}" "${MAX[$q]}"
  total=$(( total + GOT[$q] ))
done
printf 'TOTAL %d / 100  (%s)\n' "$total" "$([ "$total" -ge 66 ] && echo PASS || echo FAIL)"
