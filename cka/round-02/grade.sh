#!/usr/bin/env bash
# Round 02 grader. Prints PASS/FAIL per item and the score per question.
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
# probe <ns> <pod> <url>: does an HTTP GET from that pod succeed within 3s?
probe() { kubectl exec -n "$1" "$2" -- wget -q -T 3 -O /dev/null "$3"; }
# resolve <pod> <name> <ip>: does the name resolve to that address from the pod?
# (busybox nslookup exits 1 if any search-domain lookup fails, so ignore it)
resolve() { { kubectl exec -n r02-q2 "$1" -- nslookup -timeout=3 "$2" 2>/dev/null || true; } | grep -A1 "^Name:" | grep -q "Address:\s*$3$"; }
BACKEND_IP=$(kubectl get pod -n r02-q4 -l app=backend -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

# --- Q1 ---------------------------------------------------------------------
echo "Q1"
T="j deploy ops-agent -n r02-q1 | jq -e '.spec.template.spec"
check Q1 4 "priorityclass ops-critical = 499999, not global default" \
  "j priorityclass ops-critical | jq -e '.value==499999 and (.globalDefault // false)==false'"
check Q1 3 "$W1 tainted dedicated=ops:NoSchedule" \
  "j node $W1 | jq -e '.spec.taints | any(.key==\"dedicated\" and .value==\"ops\" and .effect==\"NoSchedule\")'"
check Q1 2 "$W1 labeled tier=ops (and no other node)" \
  "[ \"\$(kubectl get nodes -l tier=ops -o name)\" = node/$W1 ]"
check Q1 3 "required node affinity tier In/= ops" \
  "$T | .affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms
     | any(.matchExpressions | any(.key==\"tier\" and .operator==\"In\" and .values==[\"ops\"]))'"
check Q1 3 "toleration for dedicated=ops:NoSchedule" \
  "$T | .tolerations | any(.key==\"dedicated\" and ((.operator==\"Equal\" and .value==\"ops\") or .operator==\"Exists\")
     and ((.effect // \"NoSchedule\")==\"NoSchedule\"))'"
check Q1 2 "priorityClassName ops-critical" "$T | .priorityClassName==\"ops-critical\"'"
check Q1 3 "2/2 ready, all on $W1" \
  "j deploy ops-agent -n r02-q1 | jq -e '.status.readyReplicas==2 and .status.updatedReplicas==2 and .status.replicas==2' \
   && j pods -n r02-q1 -l app=ops-agent | jq -e '[.items[] | select(.metadata.deletionTimestamp|not) | .spec.nodeName] as \$n | (\$n|length)==2 and all(\$n[]; .==\"$W1\")'"

# --- Q2 ---------------------------------------------------------------------
echo "Q2"
API_IP=$(kubectl get svc api -n r02-q2 -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
check Q2 3 "Corefile serves cluster.local again" \
  "kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -qE 'kubernetes cluster\.local in-addr\.arpa ip6\.arpa'"
check Q2 2 "coredns 2/2 ready" "kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -q 'kubernetes cluster.local ' && j deploy coredns -n kube-system | jq -e '.status.readyReplicas==2'"
check Q2 4 "dns-probe resolves api.r02-q2.svc.cluster.local" "resolve dns-probe api.r02-q2.svc.cluster.local $API_IP"
check Q2 3 "client uses cluster DNS (dnsPolicy ClusterFirst), busybox sleep" \
  "j pod client -n r02-q2 | jq -e '(.spec.dnsPolicy // \"ClusterFirst\")==\"ClusterFirst\" and .spec.containers[0].image==\"busybox:1.36\" and .status.phase==\"Running\"'"
check Q2 4 "client resolves the short name api" "resolve client api $API_IP"
check Q2 4 "legacy.internal -> 172.30.0.10, external names still resolve" \
  "resolve dns-probe legacy.internal 172.30.0.10 && kubectl exec -n r02-q2 dns-probe -- nslookup -timeout=3 kubernetes.io"

# --- Q3 ---------------------------------------------------------------------
echo "Q3"
H='j hpa api -n r02-q3'
check Q3 4 "answers/q3/top-pod.txt = ingest-b41" "grep -qx 'ingest-b41' '$ANS/q3/top-pod.txt'"
check Q3 4 "api requests 100m/64Mi, cpu limit 200m" \
  "j deploy api -n r02-q3 | jq -e '.spec.template.spec.containers[0].resources | .requests.cpu==\"100m\" and .requests.memory==\"64Mi\" and .limits.cpu==\"200m\"'"
check Q3 5 "hpa api -> deployment api, 2-6, cpu 70%" \
  "$H | jq -e '.spec.scaleTargetRef.kind==\"Deployment\" and .spec.scaleTargetRef.name==\"api\" and .spec.minReplicas==2 and .spec.maxReplicas==6
     and (.spec.metrics | any(.type==\"Resource\" and .resource.name==\"cpu\" and .resource.target.type==\"Utilization\" and .resource.target.averageUtilization==70))'"
check Q3 4 "scaleDown: window 120s, 1 pod / 60s" \
  "$H | jq -e '.spec.behavior.scaleDown | .stabilizationWindowSeconds==120 and (.policies | length==1 and .[0].type==\"Pods\" and .[0].value==1 and .[0].periodSeconds==60)'"
check Q3 3 "hpa reads cpu metrics and keeps >= 2 replicas" \
  "$H | jq -e '(.status.conditions | any(.type==\"ScalingActive\" and .status==\"True\")) and .status.currentReplicas>=2'"

# --- Q4 ---------------------------------------------------------------------
echo "Q4"
check Q4 4 "backend-ingress-c applied unchanged" \
  "j netpol backend-ingress-c -n r02-q4 | jq -e '.spec.podSelector.matchLabels=={app:\"backend\"}
     and .spec.ingress==[{from:[{podSelector:{matchLabels:{app:\"frontend\"}}}],ports:[{protocol:\"TCP\",port:80}]}]'"
check Q4 3 "backend-ingress-a and -b not applied, no other policy" \
  "[ \"\$(kubectl get netpol -n r02-q4 -o name)\" = networkpolicy.networking.k8s.io/backend-ingress-c ]"
check Q4 3 "frontend -> backend:80 allowed" "j netpol -n r02-q4 | jq -e '.items|length>0' && probe r02-q4 frontend http://$BACKEND_IP"
check Q4 3 "other -> backend blocked" \
  "j netpol backend-ingress-c -n r02-q4 && probe r02-q4 frontend http://$BACKEND_IP && ! probe r02-q4 other http://$BACKEND_IP"
check Q4 3 "r02-q4-ext frontend -> backend blocked" \
  "j netpol -n r02-q4 | jq -e '.items|length>0' && probe r02-q4 frontend http://$BACKEND_IP && ! probe r02-q4-ext frontend http://$BACKEND_IP"
check Q4 4 "service backend NodePort 80 -> 80, nodePort 30080, with endpoint" \
  "j svc backend -n r02-q4 | jq -e '.spec.type==\"NodePort\" and (.spec.ports|length==1) and (.spec.ports[0] | .port==80 and .targetPort==80 and .nodePort==30080)' \
   && j endpointslices -n r02-q4 -l kubernetes.io/service-name=backend | jq -e '[.items[].endpoints[]? | select(.conditions.ready)] | length==1'"

# --- Q5 ---------------------------------------------------------------------
echo "Q5"
check Q5 6 "pvc mariadb Bound to mariadb-pv" \
  "j pvc mariadb -n r02-q5 | jq -e '.status.phase==\"Bound\" and .spec.volumeName==\"mariadb-pv\" and .spec.accessModes==[\"ReadWriteOnce\"]'"
check Q5 2 "mariadb-pv kept: Retain, 250Mi, same PV" \
  "j pvc mariadb -n r02-q5 | jq -e '.status.phase==\"Bound\"' && j pv mariadb-pv | jq -e '.spec.persistentVolumeReclaimPolicy==\"Retain\" and .spec.capacity.storage==\"250Mi\"' \
   && node $W2 'grep -qx data-from-before /mnt/mariadb/ready'"
check Q5 4 "deployment mariadb mounts claim mariadb at /var/lib/mysql" \
  "j deploy mariadb -n r02-q5 | jq -e '.spec.template.spec | (.volumes[] | select(.persistentVolumeClaim.claimName==\"mariadb\") | .name) as \$v
     | .containers[0].volumeMounts | any(.name==\$v and .mountPath==\"/var/lib/mysql\")'"
check Q5 4 "deployment mariadb 1/1 ready" "j deploy mariadb -n r02-q5 | jq -e '.status.readyReplicas==1'"
check Q5 4 "mariadb sees the existing data" \
  "[ \"\$(kubectl exec -n r02-q5 deploy/mariadb -- cat /var/lib/mysql/ready)\" = data-from-before ]"
# --- total ------------------------------------------------------------------
echo
total=0
for q in "${ORDER[@]}"; do
  printf '%s  %2d / %2d\n' "$q" "${GOT[$q]}" "${MAX[$q]}"
  total=$(( total + GOT[$q] ))
done
printf 'TOTAL %d / 100  (%s)\n' "$total" "$([ "$total" -ge 66 ] && echo PASS || echo FAIL)"
