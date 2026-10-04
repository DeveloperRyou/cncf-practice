#!/usr/bin/env bash
# Round 05 grader. Prints PASS/FAIL per item and the score per question.
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
JOB='j job etl -n r05-q1'
T="$JOB | jq -e '.spec.template.spec"
check Q1 3 "job completions=4, parallelism=2" "$JOB | jq -e '.spec.completions==4 and .spec.parallelism==2'"
check Q1 2 "job backoffLimit=1"           "$JOB | jq -e '.spec.backoffLimit==1'"
check Q1 3 "job activeDeadlineSeconds=120" "$JOB | jq -e '.spec.activeDeadlineSeconds==120'"
check Q1 2 "init container extract, main container load (busybox:1.36)" \
  "$T | (.initContainers // [] | any(.name==\"extract\" and .image==\"busybox:1.36\")) and (.containers | any(.name==\"load\" and .image==\"busybox:1.36\"))'"
check Q1 4 "emptyDir mounted at /work in extract and load" \
  "$T | [.volumes[]? | select(.emptyDir) | .name] as \$e
       | ([.initContainers[]?, .containers[]] | map(select(.name==\"extract\" or .name==\"load\"))
          | length==2 and all(any(.volumeMounts[]?; .mountPath==\"/work\" and (.name|IN(\$e[])))))'"
check Q1 4 "job succeeded 4 times"        "$JOB | jq -e '.status.succeeded==4'"
check Q1 3 "load prints 'loaded rows=42'" "kubectl logs -n r05-q1 job/etl -c load | grep -x 'loaded rows=42' >/dev/null"
check Q1 4 "answers/q1/load.log = 'loaded rows=42'" "grep -qx 'loaded rows=42' '$ANS/q1/load.log'"

# --- Q2 ---------------------------------------------------------------------
echo "Q2"
LR='j limitrange defaults -n r05-q2'
P='j pod hardened -n r05-q2'
X='kubectl exec -n r05-q2 hardened --'
S="$P | jq -e '.spec"
check Q2 4 "limitrange defaults: requests 150m/128Mi, limits 300m/256Mi" \
  "$LR | jq -e '.spec.limits | any(.type==\"Container\" and .defaultRequest.cpu==\"150m\" and .defaultRequest.memory==\"128Mi\"
     and .default.cpu==\"300m\" and .default.memory==\"256Mi\")'"
check Q2 3 "limitrange defaults: max memory 512Mi" \
  "$LR | jq -e '.spec.limits | any(.type==\"Container\" and .max.memory==\"512Mi\")'"
check Q2 4 "worker 2/2 ready, no resources in spec, quota unchanged" \
  "j deploy worker -n r05-q2 | jq -e '.status.readyReplicas==2 and (.spec.template.spec.containers[0].resources // {} | length==0)' \
   && j resourcequota team-quota -n r05-q2 | jq -e '.spec.hard | .pods==\"5\" and .[\"requests.cpu\"]==\"1\" and .[\"limits.memory\"]==\"2Gi\"'"
check Q2 3 "serviceaccount restricted automount=false" \
  "j sa restricted -n r05-q2 | jq -e '.automountServiceAccountToken==false'"
check Q2 3 "pod hardened Running as restricted (busybox:1.36)" \
  "$P | jq -e '.status.phase==\"Running\" and .spec.serviceAccountName==\"restricted\" and .spec.containers[0].image==\"busybox:1.36\"'"
check Q2 3 "hardened has no API token mounted" \
  "$P | jq -e '.status.phase==\"Running\"' && ! $X ls /var/run/secrets/kubernetes.io/serviceaccount/token"
check Q2 3 "runs as uid 2000 / gid 2000" "[ \"\$($X id -u)\" = 2000 ] && [ \"\$($X id -g)\" = 2000 ]"
check Q2 2 "pod-level runAsUser/runAsGroup 2000, runAsNonRoot" \
  "$S.securityContext | .runAsUser==2000 and .runAsGroup==2000 and .runAsNonRoot==true'"
check Q2 5 "container: no privilege escalation, read-only root fs, drop ALL" \
  "$S.containers[0].securityContext | .allowPrivilegeEscalation==false and .readOnlyRootFilesystem==true and (.capabilities.drop | index(\"ALL\"))' \
   && ! $X touch /probe"

# --- Q3 ---------------------------------------------------------------------
echo "Q3"
D='j deploy api -n r05-q3'
C="$D | jq -e '.spec.template.spec.containers[0]"
check Q3 5 "image nginx:1.27-alpine, readinessProbe httpGet / on port 80" \
  "$C | .image==\"nginx:1.27-alpine\" and .readinessProbe.httpGet.path==\"/\" and .readinessProbe.httpGet.port==80'"
check Q3 5 "3/3 replicas updated and ready" \
  "$D | jq -e '.status.updatedReplicas==3 and .status.readyReplicas==3 and .status.replicas==3'"
check Q3 3 "same Deployment, new revision (>= 4)" \
  "$D | jq -e '.metadata.annotations[\"deployment.kubernetes.io/revision\"]|tonumber>=4'"
check Q3 4 "change-cause 'v3 fixed probe'" \
  "$D | jq -e '.metadata.annotations[\"kubernetes.io/change-cause\"]==\"v3 fixed probe\"'"
check Q3 3 "answers/q3/history.txt shows 'v3 fixed probe'" \
  "grep -q REVISION '$ANS/q3/history.txt' && grep -q 'v3 fixed probe' '$ANS/q3/history.txt'"

# --- Q4 ---------------------------------------------------------------------
echo "Q4"
check Q4 5 "service cache ClusterIP 6379 -> 80 with a ready endpoint" \
  "j svc cache -n r05-q4 | jq -e '.spec.type==\"ClusterIP\" and .spec.ports[0].port==6379 and .spec.ports[0].targetPort==80' \
   && [ \"\$(ready_eps r05-q4 cache)\" = 1 ]"
check Q4 3 "networkpolicy app-egress selects role=app, Egress" \
  "j networkpolicy app-egress -n r05-q4 | jq -e '.spec.podSelector.matchLabels==({role:\"app\"}) and (.spec.policyTypes | index(\"Egress\"))'"
check Q4 4 "app -> db:5432 by name allowed"    "j networkpolicy app-egress -n r05-q4 && probe r05-q4 app http://db:5432"
check Q4 4 "app -> cache:6379 by name allowed" "j networkpolicy app-egress -n r05-q4 && probe r05-q4 app http://cache:6379"
check Q4 5 "app -> web blocked" \
  "j networkpolicy app-egress -n r05-q4 && probe r05-q4 app http://db:5432 && ! probe r05-q4 app http://web"
check Q4 4 "debug -> web still allowed" "j networkpolicy app-egress -n r05-q4 && probe r05-q4 debug http://web"

# --- total ------------------------------------------------------------------
echo
total=0
for q in "${ORDER[@]}"; do
  printf '%s  %2d / %2d\n' "$q" "${GOT[$q]}" "${MAX[$q]}"
  total=$(( total + GOT[$q] ))
done
printf 'TOTAL %d / 100  (%s)\n' "$total" "$([ "$total" -ge 66 ] && echo PASS || echo FAIL)"
