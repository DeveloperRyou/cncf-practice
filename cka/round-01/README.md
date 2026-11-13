# CKA Mock Exam -- Round 01

- Suggested time: **40 minutes** / 5 questions, 100 points total / passing
  score **66%**
- One context (`kind-cncf`) with three nodes: `cncf-control-plane`,
  `cncf-worker`, `cncf-worker2`. Work in the namespace given for each
  question.
- `ssh <node>` opens a shell on a node in the exam terminal (elsewhere:
  `docker exec -it <node> bash`). You are root there; `vim` is installed.
- File answers go under `answers/qN/` in this directory, at the path given.
  Files the setup prepared for you are under `workdir/`.
- You may use the official docs (kubernetes.io/docs, helm.sh/docs,
  gateway-api.sigs.k8s.io). Don't open `grade.sh` before you finish -- it
  reveals the grading criteria.

## Before you start

```bash
./scripts/down.sh && KIND_CONFIG=kind/cka.yaml ./scripts/up.sh   # fresh 3-node cluster
./cka/round-01/setup.sh                                          # pre-create resources (re-running resets the round)
```

When done, ask the agent to grade round 1.

---

## Question 1 (20%) -- namespace `r01-q1`

A new developer, user `ana` in group `devs`, needs access to namespace
`r01-q1`.

1. Create an RSA private key `answers/q1/ana.key` and a certificate
   signing request with common name `ana` and organization `devs`. Submit
   it to the cluster as CertificateSigningRequest `ana` (signer
   `kubernetes.io/kube-apiserver-client`, valid for **1 day**), approve it,
   and save the issued certificate to `answers/q1/ana.crt`.
2. Create Role `pod-operator` in `r01-q1` that allows `get`, `list`,
   `watch`, `create` and `delete` on pods, `get` on the pods' logs, and
   `get`, `list` on deployments -- nothing more. Bind it with RoleBinding
   `pod-operator-devs` to the **group** `devs` (not to the user).
3. Write a standalone kubeconfig `answers/q1/ana.kubeconfig` for `ana`:
   cluster entry with the API server and CA of `kind-cncf`, user `ana`
   with the key and certificate embedded, and context `ana@cncf` (namespace
   `r01-q1`) set as the current context. `kubectl --kubeconfig
   answers/q1/ana.kubeconfig get pods` must work as is.

## Question 2 (20%) -- namespace `r01-q2` (troubleshooting)

Node `cncf-worker2` is `NotReady`, and pod `node-check` (pinned to that
node) never starts.

1. Find and fix the cause so that `cncf-worker2` is `Ready` and stays so
   after the node reboots.
2. Pod `node-check` must be `Running`. Don't recreate it.
3. Write the full path of the file you had to fix on the node to
   `answers/q2/cause.txt` (one line).

## Question 3 (20%) -- namespace `r01-q3`

The Helm chart `workdir/charts/beacon` deploys a probe Deployment and also
renders its own CustomResourceDefinition.

1. Render the chart with `helm template` as release `beacon` in namespace
   `r01-q3`, with **3** replicas and **without** the
   CustomResourceDefinition. Save the output to `answers/q3/beacon.yaml`.
   Don't edit the chart.
2. Install the chart as release `beacon` in namespace `r01-q3` with **2**
   replicas, this time including the CRD. Its Deployment must be ready.
3. Create a `Beacon` named `edge` in `r01-q3` that probes the targets
   `api` and `db` every `30s`.
4. Save the output of `kubectl explain` for the field `spec.interval` of
   `Beacon` to `answers/q3/interval.txt`.

## Question 4 (20%) -- namespace `r01-q4` (storage)

PersistentVolume `logs-pv` holds logs on a node-local disk, but
PersistentVolumeClaim `logs-pvc` stays `Pending`.

1. Create StorageClass `local-logs` with provisioner
   `kubernetes.io/no-provisioner`, volume binding mode
   `WaitForFirstConsumer` and reclaim policy `Retain`. Make it the
   cluster's **only** default StorageClass.
2. Make `logs-pvc` (same name, `r01-q4`) bind to `logs-pv`. Don't modify
   the PV. Request exactly the PV's capacity.
3. Create pod `logs-reader` (image `busybox:1.36`, command `sleep 1d`) that
   mounts `logs-pvc` at `/logs` **read-only**. `/logs/seed.txt` must be
   readable from it.

## Question 5 (20%) -- namespace `r01-q5` (Gateway API)

Ingress `web` in `r01-q5` must be migrated to Gateway API. The Gateway API
CRDs and GatewayClass `nginx` are installed (no controller is running, so
status won't be reported; only the objects are graded).

1. Create Gateway `web-gw` (class `nginx`) with a single listener named
   `https`: protocol `HTTPS`, port `443`, the same hostname as the Ingress,
   terminating TLS with the Ingress's certificate Secret.
2. Create HTTPRoute `web-route` attached to `web-gw` that serves the same
   hostname and routes the same paths (same match type) to the same
   backend Services and ports as the Ingress.
3. Delete Ingress `web`.
