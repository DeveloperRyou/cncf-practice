#!/usr/bin/env bash
# Round 01 grader. Prints PASS/FAIL per item and the score per question.
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

# --- Q1 ---------------------------------------------------------------------
echo "Q1"
JOB='j job report-gen -n r01-q1'
T="$JOB | jq -e '.spec.template.spec"
check Q1 2 "job completions=3"          "$JOB | jq -e '.spec.completions==3'"
check Q1 2 "job parallelism=3"          "$JOB | jq -e '.spec.parallelism==3'"
check Q1 2 "job backoffLimit=2"         "$JOB | jq -e '.spec.backoffLimit==2'"
check Q1 2 "pod label app=report"       "$JOB | jq -e '.spec.template.metadata.labels.app==\"report\"'"
check Q1 2 "init container prepare (busybox:1.36), main container worker" \
  "$T | (.initContainers // [] | any(.name==\"prepare\" and .image==\"busybox:1.36\")) and (.containers | any(.name==\"worker\"))'"
check Q1 3 "emptyDir shared, mounted at /data in prepare and worker" \
  "$T | [.volumes[]? | select(.emptyDir) | .name] as \$e
       | ([.initContainers[]?, .containers[]] | map(select(.name==\"prepare\" or .name==\"worker\"))
          | length==2 and all(any(.volumeMounts[]?; .mountPath==\"/data\" and (.name|IN(\$e[])))))'"
check Q1 3 "job succeeded 3 times"      "$JOB | jq -e '.status.succeeded==3'"
check Q1 2 "answers/q1/worker.log has worker output" "grep -qx 'report-ready' '$ANS/q1/worker.log'"

# --- Q2 ---------------------------------------------------------------------
echo "Q2"
D='j deploy web -n r01-q2'
check Q2 4 "image nginx:1.27-alpine"    "$D | jq -e '.spec.template.spec.containers[0].image==\"nginx:1.27-alpine\"'"
check Q2 3 "3/3 replicas updated and ready" \
  "$D | jq -e '.status.updatedReplicas==3 and .status.readyReplicas==3 and .status.replicas==3'"
check Q2 2 "maxSurge=1"                 "$D | jq -e '.spec.strategy.rollingUpdate.maxSurge==1'"
check Q2 2 "maxUnavailable=0"           "$D | jq -e '.spec.strategy.rollingUpdate.maxUnavailable==0'"
check Q2 3 "change-cause 'upgrade to 1.27-alpine'" \
  "$D | jq -e '.metadata.annotations[\"kubernetes.io/change-cause\"]==\"upgrade to 1.27-alpine\"'"
check Q2 3 "rolled back via rollout undo (revision >= 4)" \
  "$D | jq -e '.metadata.annotations[\"deployment.kubernetes.io/revision\"]|tonumber>=4'"
check Q2 3 "answers/q2/history.txt is rollout history" \
  "grep -q REVISION '$ANS/q2/history.txt' && grep -q 'upgrade to 1.27-alpine' '$ANS/q2/history.txt'"

# --- Q3 ---------------------------------------------------------------------
echo "Q3"
D='j deploy api -n r01-q3'
C="$D | jq -e '.spec.template.spec.containers[0]"
check Q3 4 "api 2/2 ready"              "$D | jq -e '.spec.replicas==2 and .status.readyReplicas==2 and .status.updatedReplicas==2'"
check Q3 3 "readinessProbe httpGet / on port 80" \
  "$C | .readinessProbe.httpGet | .path==\"/\" and (.port==80 or .port==\"http\")'"
check Q3 3 "livenessProbe tcpSocket on port 80" \
  "$C | .livenessProbe.tcpSocket.port==80 or .livenessProbe.tcpSocket.port==\"http\"'"
check Q3 2 "live api pods have 0 restarts" \
  "j pods -n r01-q3 -l app=api | jq -e '[.items[] | select(.metadata.deletionTimestamp|not)] | length==2 and all(.status.containerStatuses[0].restartCount==0)'"
check Q3 5 "answers/q3/exit-code.txt = crasher's exit code" "[ \"\$(tr -d '[:space:]' < '$ANS/q3/exit-code.txt')\" = 3 ]"

# --- Q4 ---------------------------------------------------------------------
echo "Q4"
P='j pod secure-app -n r01-q4'
X='kubectl exec -n r01-q4 secure-app --'
S="$P | jq -e '.spec"
check Q4 2 "configmap app-config LOG_LEVEL=debug" "j cm app-config -n r01-q4 | jq -e '.data.LOG_LEVEL==\"debug\"'"
check Q4 1 "configmap app-config app.properties" \
  "j cm app-config -n r01-q4 | jq -e '.data[\"app.properties\"] | split(\"\\n\") | index([\"cache.size=128\"]) and index([\"feature.x=on\"])'"
check Q4 2 "secret db-cred (Opaque) user/password" \
  "j secret db-cred -n r01-q4 | jq -e '.type==\"Opaque\" and (.data.user|@base64d)==\"admin\" and (.data.password|@base64d)==\"S3cr3t!\"'"
check Q4 2 "serviceaccount app-sa automount=false" "j sa app-sa -n r01-q4 | jq -e '.automountServiceAccountToken==false'"
check Q4 2 "pod Running with serviceAccountName app-sa" "$P | jq -e '.status.phase==\"Running\" and .spec.serviceAccountName==\"app-sa\"'"
check Q4 2 "LOG_LEVEL from configMapKeyRef, value debug" \
  "$S.containers[0].env[]? | select(.name==\"LOG_LEVEL\") | .valueFrom.configMapKeyRef | .name==\"app-config\" and .key==\"LOG_LEVEL\"' && [ \"\$($X printenv LOG_LEVEL)\" = debug ]"
check Q4 3 "DB_PASSWORD from secretKeyRef, value S3cr3t!" \
  "$S.containers[0].env[]? | select(.name==\"DB_PASSWORD\") | .valueFrom.secretKeyRef | .name==\"db-cred\" and .key==\"password\"' && [ \"\$($X printenv DB_PASSWORD)\" = 'S3cr3t!' ]"
check Q4 3 "/etc/app holds only app.properties" \
  "$X grep -qx cache.size=128 /etc/app/app.properties && [ \"\$($X ls /etc/app)\" = app.properties ]"
check Q4 2 "runs as uid 1000 / gid 3000" "[ \"\$($X id -u)\" = 1000 ] && [ \"\$($X id -g)\" = 3000 ]"
check Q4 1 "runAsNonRoot=true" "$S | .securityContext.runAsNonRoot==true or .containers[0].securityContext.runAsNonRoot==true'"
check Q4 2 "allowPrivilegeEscalation=false, root fs read-only" \
  "$S.containers[0].securityContext.allowPrivilegeEscalation==false' && ! $X touch /probe"
check Q4 1 "capabilities drop ALL" "$S.containers[0].securityContext.capabilities.drop | index(\"ALL\")'"
check Q4 2 "requests 50m/32Mi, limits 100m/64Mi" \
  "$S.containers[0].resources | .requests.cpu==\"50m\" and .requests.memory==\"32Mi\" and .limits.cpu==\"100m\" and .limits.memory==\"64Mi\"'"

# --- Q5 ---------------------------------------------------------------------
echo "Q5"
URL=http://backend-svc.r01-q5.svc.cluster.local
NP='j networkpolicy allow-frontend -n r01-q5'
check Q5 4 "backend-svc has 2 ready endpoints" \
  "j endpointslices -n r01-q5 -l kubernetes.io/service-name=backend-svc | jq -e '[.items[].endpoints[]? | select(.conditions.ready)] | length==2'"
check Q5 1 "backend-svc still ClusterIP on port 80" \
  "j svc backend-svc -n r01-q5 | jq -e '.spec.type==\"ClusterIP\" and .spec.ports[0].port==80'"
check Q5 2 "networkpolicy allow-frontend selects app=backend" "$NP | jq -e '.spec.podSelector.matchLabels==({app:\"backend\"})'"
check Q5 1 "policyTypes includes Ingress" "$NP | jq -e '.spec.policyTypes | index(\"Ingress\")'"
check Q5 3 "r01-q5/frontend -> backend-svc allowed" "probe r01-q5 frontend $URL"
check Q5 3 "r01-q5-mon/prober -> backend-svc allowed" "probe r01-q5-mon prober $URL"
check Q5 3 "r01-q5/intruder -> backend-svc blocked" "probe r01-q5 frontend $URL && ! probe r01-q5 intruder $URL"
check Q5 3 "r01-q5-ext/frontend -> backend-svc blocked" "probe r01-q5 frontend $URL && ! probe r01-q5-ext frontend $URL"

# --- total ------------------------------------------------------------------
echo
total=0
for q in "${ORDER[@]}"; do
  printf '%s  %2d / %2d\n' "$q" "${GOT[$q]}" "${MAX[$q]}"
  total=$(( total + GOT[$q] ))
done
printf 'TOTAL %d / 100  (%s)\n' "$total" "$([ "$total" -ge 66 ] && echo PASS || echo FAIL)"
