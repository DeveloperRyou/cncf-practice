# CKAD Mock Exam -- Round 04

- Suggested time: **30 minutes** / 4 questions, 100 points total / passing
  score **66%**
- There is a single context (`kind-cncf`), so no context switching. Work in
  the namespace given for each question.
- File answers go under `answers/qN/` in this directory, at the path given.
- You may use the official docs (kubernetes.io/docs). Don't open
  `grade.sh` before you finish -- it reveals the grading criteria.

## Before you start

```bash
./scripts/down.sh && ./scripts/up.sh   # fresh cluster
./ckad/round-04/setup.sh               # pre-create resources (re-running resets r04-*)
```

When done, ask the agent to grade round 4.

---

## Question 1 (30%) -- namespace `r04-q1`

A CI system will update Deployment `app` (already exists) through its own
ServiceAccount.

1. Create ServiceAccount `deployer`.
2. Create Role `deployer` that allows `get`, `list`, `patch`, `update` on
   **deployments**, and `get`, `list` on **pods** -- nothing else -- and
   RoleBinding `deployer` that grants it to ServiceAccount `deployer`.
3. Using `kubectl auth can-i ... --as=system:serviceaccount:r04-q1:deployer`,
   save the answer (`yes`/`no` only) to "can it patch deployments in
   `r04-q1`?" to `answers/q1/can-patch.txt`, and to "can it delete
   deployments in `r04-q1`?" to `answers/q1/can-delete.txt`.
4. Make the pods of Deployment `app` run as ServiceAccount `deployer`,
   **without** an API token mounted (set this in the pod template).
   Both replicas must be Ready.

## Question 2 (25%) -- namespace `r04-q2`

1. Create PersistentVolumeClaim `data`: StorageClass `standard`, access
   mode `ReadWriteOnce`, `100Mi`.
2. Create Pod `writer`, image `busybox:1.36`, that mounts `data` at
   `/data`:
   - Env var `MY_POD` holds the pod's own name and `MY_NODE` the name of
     its node (Downward API).
   - On start it appends the line `<pod name> on <node name>` (from those
     env vars) to `/data/owners.txt`, then sleeps for 3600 seconds.
3. Create Pod `reader`, image `busybox:1.36`, command `sleep 3600`, that
   mounts `data` **read-only** at `/data`.

`kubectl exec reader -n r04-q2 -- cat /data/owners.txt` must show the
line written by `writer`.

## Question 3 (20%) -- namespace `r04-q3`

A Kustomize base is in `ckad/round-04/q3/base` (created by `setup.sh`). Do
not modify the base.

Create the overlay `ckad/round-04/q3/overlays/prod/kustomization.yaml` so
that, built from the base, it:

- puts every resource in namespace `r04-q3`,
- prefixes every resource name with `prod-`,
- adds the label `env=prod` to every resource and to the pod template,
- uses image `nginx:1.27-alpine` instead of the base's nginx image,
- runs **3** replicas of the Deployment.

Apply it with `kubectl apply -k`. All 3 pods must be Ready.

## Question 4 (25%) -- namespace `r04-q4` (troubleshooting)

Pods `app=api` (Deployment `api`, Service `api` on port 80) are protected
by NetworkPolicy `default-deny` (deny all ingress) and should be reachable
through NetworkPolicy `allow-api`, but the allowed clients can't connect.

Fix `allow-api` (don't change `default-deny`) so that ingress to `app=api`
pods on **TCP 80** is allowed only from:

- pods labeled `role=frontend` in `r04-q4`, and
- all pods in namespaces labeled `team=monitoring`.

Pods to test with: `r04-q4/frontend` and `r04-q4-mon/prober` (allowed);
`r04-q4/intruder` and `r04-q4-other/frontend` (denied).
