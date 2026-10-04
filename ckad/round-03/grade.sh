#!/usr/bin/env bash
# Round 03 grader. Prints PASS/FAIL per item and the score per question.
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
D='j deploy app -n r03-q1'
T="$D | jq -e '.spec.template.spec"
SC="$T.initContainers[]? | select(.name==\"log-shipper\")"
X='kubectl exec -n r03-q1 deploy/app -c app --'
check Q1 3 "deployment app: 1 replica, label app=app, 1/1 ready" \
  "$D | jq -e '.spec.replicas==1 and .spec.template.metadata.labels.app==\"app\" and .status.readyReplicas==1'"
check Q1 2 "emptyDir volume 'logs'" "$T.volumes | any(.name==\"logs\" and .emptyDir)'"
check Q1 3 "container app (busybox:1.36) mounts logs at /var/log/app" \
  "$T.containers | any(.name==\"app\" and .image==\"busybox:1.36\" and any(.volumeMounts[]?; .name==\"logs\" and .mountPath==\"/var/log/app\"))'"
check Q1 5 "log-shipper is a native sidecar (initContainer, restartPolicy Always)" \
  "$SC | .restartPolicy==\"Always\" and .image==\"busybox:1.36\"'"
check Q1 3 "log-shipper mounts logs read-only at /var/log/app" \
  "$SC | any(.volumeMounts[]?; .name==\"logs\" and .mountPath==\"/var/log/app\" and .readOnly==true)'"
check Q1 3 "app.log keeps getting 'tick' lines" \
  "[ \"\$($X grep -cx tick /var/log/app/app.log)\" -ge 2 ]"
check Q1 3 "log-shipper logs show the ticks" \
  "kubectl logs -n r03-q1 deploy/app -c log-shipper --tail=20 | grep -x tick >/dev/null"
check Q1 3 "answers/q1/shipper.log has ticks" "grep -qx tick '$ANS/q1/shipper.log'"

# --- Q2 ---------------------------------------------------------------------
echo "Q2"
H='helm -n r03-q2'
REL() { j deploy -n r03-q2 -l "app.kubernetes.io/instance=$1" | jq -e ".items | length==1 and (.[0] | $2)"; }
check Q2 4 "release legacy uninstalled" "$H list -q >/dev/null && ! $H status legacy"
check Q2 4 "api rolled back (revision >= 3, deployed, image 1.26-alpine)" \
  "$H history api -o json | jq -e 'last | .revision>=3 and .status==\"deployed\"' \
   && REL api '.spec.template.spec.containers[0].image==\"nginx:1.26-alpine\"'"
check Q2 3 "api pods ready" "REL api '.status.readyReplicas==.spec.replicas and .status.updatedReplicas==.spec.replicas and .status.replicas==.spec.replicas'"
check Q2 3 "shop installed from the webapp chart" \
  "$H list -o json | jq -e 'any(.name==\"shop\" and (.chart|startswith(\"webapp-\")) and .status==\"deployed\")'"
check Q2 4 "shop values replicaCount=2, image.tag=1.27-alpine" \
  "$H get values shop -o json | jq -e '.replicaCount==2 and .image.tag==\"1.27-alpine\"'"
check Q2 4 "shop 2/2 ready on nginx:1.27-alpine" \
  "REL shop '.status.readyReplicas==2 and .spec.template.spec.containers[0].image==\"nginx:1.27-alpine\"'"
check Q2 3 "answers/q2/history.txt is helm history of api with the rollback" \
  "grep -q REVISION '$ANS/q2/history.txt' && grep -qi 'rollback to' '$ANS/q2/history.txt'"

# --- Q3 ---------------------------------------------------------------------
echo "Q3"
D='j deploy importer -n r03-q3'
check Q3 4 "answers/q3/exit-code.txt = 2" "[ \"\$(tr -d '[:space:]' < '$ANS/q3/exit-code.txt')\" = 2 ]"
check Q3 4 "answers/q3/reason.txt = Error" "[ \"\$(tr -d '[:space:]' < '$ANS/q3/reason.txt')\" = Error ]"
check Q3 4 "answers/q3/previous.log has the crash message" \
  "grep -q 'missing /config/settings.ini' '$ANS/q3/previous.log'"
check Q3 4 "configmap importer-config has settings.ini=mode=full" \
  "j cm importer-config -n r03-q3 | jq -e '.data[\"settings.ini\"] | rtrimstr(\"\\n\")==\"mode=full\"'"
check Q3 2 "deployment command unchanged (and pod ready)" \
  "$D | jq -e '.status.readyReplicas==1 and (.spec.template.spec.containers[0].command[2] | contains(\"/config/settings.ini\"))'"
check Q3 4 "importer 1/1 ready and importing with mode=full" \
  "$D | jq -e '.status.readyReplicas==1' && kubectl logs -n r03-q3 deploy/importer | grep 'importing with mode=full' >/dev/null"
check Q3 3 "importer container currently running" \
  "j pods -n r03-q3 -l app=importer | jq -e '[.items[] | select(.metadata.deletionTimestamp|not)] | length==1 and all(.status.containerStatuses[0].state.running)'"

# --- Q4 ---------------------------------------------------------------------
echo "Q4"
ING='j ingress shop -n r03-q4'
check Q4 4 "web-svc ClusterIP 80 -> 80 with 2 ready endpoints" \
  "j svc web-svc -n r03-q4 | jq -e '.spec.type==\"ClusterIP\" and .spec.ports[0].port==80 and .spec.ports[0].targetPort==80' \
   && [ \"\$(ready_eps r03-q4 web-svc)\" = 2 ]"
check Q4 5 "api-svc ClusterIP 8080 -> named port http with 2 ready endpoints" \
  "j svc api-svc -n r03-q4 | jq -e '.spec.type==\"ClusterIP\" and .spec.ports[0].port==8080 and .spec.ports[0].targetPort==\"http\"' \
   && [ \"\$(ready_eps r03-q4 api-svc)\" = 2 ]"
check Q4 4 "secret shop-tls (kubernetes.io/tls) from the given files" \
  "j secret shop-tls -n r03-q4 | jq -e --arg c \"\$(base64 -w0 < '$ANS/../q4/tls.crt')\" '.type==\"kubernetes.io/tls\" and .data[\"tls.crt\"]==\$c'"
check Q4 2 "ingress shop: class nginx, host shop.example.com" \
  "$ING | jq -e '.spec.ingressClassName==\"nginx\" and (.spec.rules | length==1) and .spec.rules[0].host==\"shop.example.com\"'"
check Q4 4 "ingress tls: shop.example.com with shop-tls" \
  "$ING | jq -e '.spec.tls | any(.secretName==\"shop-tls\" and (.hosts | index(\"shop.example.com\")))'"
check Q4 3 "ingress / Prefix -> web-svc:80" \
  "$ING | jq -e '.spec.rules[0].http.paths | any(.path==\"/\" and .pathType==\"Prefix\" and .backend.service.name==\"web-svc\" and .backend.service.port.number==80)'"
check Q4 3 "ingress /api Prefix -> api-svc:8080" \
  "$ING | jq -e '.spec.rules[0].http.paths | any(.path==\"/api\" and .pathType==\"Prefix\" and .backend.service.name==\"api-svc\" and .backend.service.port.number==8080)'"

# --- total ------------------------------------------------------------------
echo
total=0
for q in "${ORDER[@]}"; do
  printf '%s  %2d / %2d\n' "$q" "${GOT[$q]}" "${MAX[$q]}"
  total=$(( total + GOT[$q] ))
done
printf 'TOTAL %d / 100  (%s)\n' "$total" "$([ "$total" -ge 66 ] && echo PASS || echo FAIL)"
