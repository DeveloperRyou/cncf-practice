# CKA Mock Exam -- Round 03

- Suggested time: **40 minutes** / 5 questions, 100 points total / passing
  score **66%**
- One context (`kind-cncf`) with three nodes: `cncf-control-plane`,
  `cncf-worker`, `cncf-worker2`. Work in the namespace given for each
  question.
- `ssh <node>` opens a shell on a node in the exam terminal (elsewhere:
  `docker exec -it <node> bash`). You are root there; `vim` and `crictl`
  are installed.
- File answers go under `answers/qN/` in this directory, at the path given.
  Files the setup prepared for you are under `workdir/`.
- You may use the official docs (kubernetes.io/docs). Don't open
  `grade.sh` before you finish -- it reveals the grading criteria.

## Before you start

```bash
./scripts/down.sh && KIND_CONFIG=kind/cka.yaml ./scripts/up.sh   # fresh 3-node cluster
./cka/round-03/setup.sh                                          # pre-create resources (re-running resets the round)
```

When done, ask the agent to grade round 3.

---

## Question 1 (20%) -- namespace `r03-q1` (troubleshooting)

The pods of Deployment `queue` in `r03-q1` stay `Pending`.

1. Find and fix the cause. Both replicas of `queue` must be Running. Don't
   modify the Deployment.
2. Write this cluster's Service IP range (CIDR) to
   `answers/q1/service-cidr.txt` and its Pod IP range (CIDR) to
   `answers/q1/pod-cidr.txt`, one line each, as configured in the control
   plane components.

## Question 2 (20%) -- namespace `r03-q2`

1. Create a **static pod** `health-probe` on node `cncf-worker2`, in
   namespace `r03-q2`: image `nginx:1.27-alpine`, label `app=health-probe`,
   container port `80`, CPU request `10m`. Don't change the kubelet's
   configuration.
2. Write the directory you put the manifest in to
   `answers/q2/static-path.txt` (one line).
3. Write the container runtime and its version on `cncf-worker2`, as the
   node reports it (format `<runtime>://<version>`), to
   `answers/q2/runtime.txt`.

## Question 3 (20%) -- namespace `r03-q3`

Create DaemonSet `log-agent` whose pods run on **every** node of the
cluster, the control plane included.

- An `emptyDir` volume `logs` is mounted at `/var/log/app` by both
  containers below.
- Main container `app` (image `busybox:1.36`) appends the output of `date`
  to `/var/log/app/app.log` every 5 seconds.
- Container `shipper` (image `busybox:1.36`) runs `tail -F
  /var/log/app/app.log`. It must be a **native sidecar**: started before
  `app` and kept running alongside it for the pod's whole life.
- Both containers request `10m` CPU and `16Mi` memory.
- Updates replace pods one node at a time by starting the new pod **before**
  the old one stops (`maxSurge 1`, `maxUnavailable 0`).

## Question 4 (20%) -- namespace `r03-q4`

Deployments `shop` and `static` run nginx on port 80. Service `static`
works, but Service `shop` has no endpoints.

1. Fix Service `shop` so it sends port `80` to the `shop` pods' container
   port **by its name**. Don't change the Deployment.
2. Create a TLS Secret `shop-tls` from `workdir/shop.crt` and
   `workdir/shop.key`.
3. Create Ingress `shop` (ingress class `nginx`) for host
   `shop.example.com`, TLS-terminated with `shop-tls`:
   - path `/api` (prefix) goes to Service `shop` port `80`,
   - path `/` (prefix) goes to Service `static` port `80`.

## Question 5 (20%) -- namespaces `r03-q5`, `r03-q5-staging`

ServiceAccount `deployer` in `r03-q5` is used by a CI pipeline. It can
currently do far more than it should.

1. Create ClusterRole `deploy-manager` allowing `get`, `list`, `watch`,
   `create`, `update`, `patch` and `delete` on deployments, and `get`,
   `update`, `patch` on their `scale` subresource.
2. Let `deployer` use `deploy-manager` **only** in namespaces `r03-q5` and
   `r03-q5-staging`, with a RoleBinding named `deployer` in each.
3. Create ClusterRole `node-reader` (`get`, `list` on nodes) and bind it to
   `deployer` with ClusterRoleBinding `deployer-node-reader`.
4. Make sure `deployer` has no other permissions beyond the defaults every
   ServiceAccount gets.
