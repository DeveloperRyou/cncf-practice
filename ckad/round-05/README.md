# CKAD Mock Exam -- Round 05

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
./ckad/round-05/setup.sh               # pre-create resources (re-running resets r05-*)
```

When done, ask the agent to grade round 5.

---

## Question 1 (25%) -- namespace `r05-q1`

Create a Job named `etl`.

- It must complete **4** successful runs, at most **2** pods at a time.
  Retry failed pods at most **1** time. The whole Job is terminated if it
  runs longer than **120 seconds**.
- The pod has one `emptyDir` volume mounted at `/work` by both containers:
  - Init container `extract`, image `busybox:1.36`: writes `rows=42` to
    `/work/data.txt`.
  - Main container `load`, image `busybox:1.36`: prints `loaded ` followed
    by the content of `/work/data.txt` (that is, `loaded rows=42`) and
    exits.

Once the Job has completed, save the logs of the `load` container of one
of its pods to `answers/q1/load.log`.

## Question 2 (30%) -- namespace `r05-q2`

The namespace has a ResourceQuota, and Deployment `worker` has no running
pods.

1. Create a LimitRange `defaults` so that containers that don't set
   resources get requests `cpu: 150m`, `memory: 128Mi` and limits
   `cpu: 300m`, `memory: 256Mi`, and no container may set a memory limit
   above `512Mi`. Then make `worker` run **2/2** Ready pods without
   changing the ResourceQuota or the `worker` Deployment spec.
2. Create ServiceAccount `restricted` that does **not** automount an API
   token (set this on the ServiceAccount).
3. Create Pod `hardened`: image `busybox:1.36`, command `sleep 3600`,
   ServiceAccount `restricted`, no `resources` in its spec, and:
   - runs as UID `2000` and GID `2000`, with `runAsNonRoot: true`
     (pod level);
   - no privilege escalation, read-only root filesystem, all capabilities
     dropped (container level).

## Question 3 (20%) -- namespace `r05-q3` (troubleshooting)

The latest rollout of Deployment `api` (image `nginx:1.27-alpine`) never
completes: its new pod never becomes Ready, so the old pods keep serving.

1. Fix the Deployment's readinessProbe so it checks path `/` on port 80,
   keeping image `nginx:1.27-alpine`. All 3 replicas must be updated and
   Ready.
2. Record the change-cause of the resulting revision as
   `v3 fixed probe`.
3. Save the output of `kubectl rollout history deploy api -n r05-q3` to
   `answers/q3/history.txt` (it must show `v3 fixed probe`).

## Question 4 (25%) -- namespace `r05-q4`

Deployments `db` (pods `app=db`), `cache` (pods `app=cache`) and `web`
(pods `app=web`) run nginx on port 80. Service `db` already exposes `db`
on port **5432**.

1. Create Service `cache` (ClusterIP) that exposes the `cache` pods on port
   **6379**, forwarding to container port 80.
2. Create NetworkPolicy `app-egress` that restricts **egress** of pods
   labeled `role=app`. They may only:
   - resolve DNS (UDP and TCP port 53, any destination),
   - reach Service `db` on port 5432 and Service `cache` on port 6379.

   Pods to test with: `r05-q4/app` must reach `db:5432` and `cache:6379`
   by name but not `web`; `r05-q4/debug` must still reach `web`.
