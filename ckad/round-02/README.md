# CKAD Mock Exam -- Round 02

- Suggested time: **40 minutes** / 5 questions, 100 points total / passing
  score **66%**
- There is a single context (`kind-cncf`), so no context switching. Work in
  the namespace given for each question.
- File answers go under `answers/qN/` in this directory, at the path given.
- You may use the official docs (kubernetes.io/docs). Don't open
  `grade.sh` before you finish -- it reveals the grading criteria.

## Before you start

```bash
./scripts/down.sh && ./scripts/up.sh   # fresh cluster
./ckad/round-02/setup.sh               # pre-create resources (re-running resets r02-*)
```

When done, ask the agent to grade round 2.

---

## Question 1 (18%) -- namespace `r02-q1`

Create a CronJob named `backup`.

- Schedule: every day at **02:30**.
- A new Job must never start while the previous one is still running.
  Keep the **2** most recent successful Jobs and the **1** most recent
  failed Job.
- Each Job is terminated if it runs longer than **40 seconds**. Failed
  containers are restarted in place (`restartPolicy: OnFailure`).
- One container `backup`, image `busybox:1.36`:
  - Env var `NODE_NAME` holds the name of the node the pod runs on (use
    the Downward API, don't hard-code it).
  - It prints the line `backup done on <node name>` (using `NODE_NAME`)
    and exits successfully.

The schedule won't fire during the exam. Create a Job named
`backup-manual` **from the CronJob** (don't write a separate Job spec),
wait for it to complete, and save its logs to `answers/q1/backup.log`.

## Question 2 (20%) -- namespace `r02-q2`

Deployment `shop-v1` serves the current version through Service `shop`.
Roll out a canary of the new version next to it.

1. Create Deployment `shop-v2`:
   - 1 replica, container `nginx`, image `nginx:1.27-alpine`.
   - Pod labels `app=shop` and `version=v2`.
   - Mount ConfigMap `html-v2` (already exists) at
     `/usr/share/nginx/html`.
   - readinessProbe: `httpGet`, path `/`, port 80.
2. Scale `shop-v1` to **3** replicas, so the canary receives about 25% of
   the traffic.
3. Change Service `shop` so it load-balances across the `shop-v1` **and**
   `shop-v2` pods. Keep its name, type (ClusterIP) and port 80.

Pod `r02-q2/client` can be used for testing (`wget -qO- shop`).

## Question 3 (17%) -- namespace `r02-q3` (troubleshooting)

1. The pods of Deployment `worker` never start. Each container is meant to
   print `working` every 5 seconds, forever. Fix the Deployment so both
   replicas run (keep the image and that behavior).
2. The pod of Deployment `cache-warmer` keeps restarting.
   - Write the **reason** its container was last terminated, exactly as
     Kubernetes reports it (one word), to `answers/q3/reason.txt`.
   - Fix it by changing **only** the container's memory limit, to
     `128Mi`. The pod must then keep running.

## Question 4 (25%) -- namespace `r02-q4`

The namespace has a ResourceQuota. Deployment `report` currently has no
running pods.

1. Create a LimitRange `container-defaults` so that containers that don't
   set resources get requests `cpu: 100m`, `memory: 64Mi` and limits
   `cpu: 200m`, `memory: 128Mi`. Then make `report` run **2/2** Ready
   pods. Don't change the ResourceQuota and don't add resources to the
   `report` Deployment spec.
2. Create ServiceAccount `pod-reader`, a Role `pod-reader` that allows
   `get`, `list`, `watch` on pods and `get` on pod logs (nothing else),
   and a RoleBinding `pod-reader` that grants the Role to the
   ServiceAccount.
3. Using `kubectl auth can-i ... --as=system:serviceaccount:r02-q4:pod-reader`,
   save the answer to "can it list pods in `r02-q4`?" to
   `answers/q4/can-list.txt` and to "can it delete pods in `r02-q4`?" to
   `answers/q4/can-delete.txt` (the `yes`/`no` output only).
4. Create Pod `audit`: image `busybox:1.36`, command `sleep 3600`, no
   `resources` in its spec.
   - Runs as ServiceAccount `pod-reader`.
   - Env vars `POD_NAME` and `POD_NAMESPACE` hold the pod's own name and
     namespace (Downward API).
   - Secret `api-token` (already exists) mounted read-only at
     `/etc/token`, with file mode `0400`.

## Question 5 (20%) -- namespace `r02-q5`

Deployments `app-a` (pods `app=a`) and `app-b` (pods `app=b`) run nginx on
port 80.

1. Create Service `svc-a` (ClusterIP) that exposes `app-a` on port
   **8080**, forwarding to container port 80.
2. Create Service `svc-b` (NodePort) that exposes `app-b` on port 80,
   forwarding to container port 80, with node port **30080**.
3. Create Ingress `web` with ingress class `nginx` and host `shop.local`:
   path `/a` (Prefix) goes to `svc-a`, path `/b` (Prefix) goes to
   `svc-b`. (No ingress controller is installed; only the object is
   checked.)
4. Create NetworkPolicy `client-egress` that restricts **egress** of pods
   labeled `role=client`. They may only:
   - resolve DNS (UDP and TCP port 53, any destination), and
   - connect to pods labeled `app=a` on TCP port 80.

   Pods to test with: `r02-q5/client` must reach `svc-a:8080` by name but
   not `svc-b`; `r02-q5/other` must still reach `svc-b`.
