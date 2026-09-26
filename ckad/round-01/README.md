# CKAD Mock Exam -- Round 01

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
./ckad/round-01/setup.sh               # pre-create resources (re-running resets r01-*)
```

When done, ask the agent to grade round 1.

---

## Question 1 (18%) -- namespace `r01-q1`

Create a Job named `report-gen`.

- It must complete **3** successful runs, with **3** pods running in
  **parallel**. Retry failed pods at most **2** times.
- The pod template has the label `app=report`.
- The pod has one `emptyDir` volume, mounted at `/data` by both containers
  below.
  - Init container `prepare`: image `busybox:1.36`, writes the string
    `report-ready` to the file `/data/status`.
  - Main container `worker`: image `busybox:1.36`, prints `/data/status`
    to standard output and exits.
- Once the Job has completed, save the logs of the `worker` container of
  one of its pods to `answers/q1/worker.log`.

## Question 2 (20%) -- namespace `r01-q2`

Since its most recent update, Deployment `web` fails to bring up new pods.

1. Use `kubectl rollout` to roll back to the last working revision (do not
   delete and recreate the Deployment).
2. Change the update strategy to `RollingUpdate` with `maxSurge: 1` and
   `maxUnavailable: 0`.
3. Update the image to `nginx:1.27-alpine` and record the change-cause of
   this revision as `upgrade to 1.27-alpine`. All 3 replicas must be Ready
   on the new image.
4. Save the output of `kubectl rollout history deploy web -n r01-q2` to
   `answers/q2/history.txt`.

## Question 3 (17%) -- namespace `r01-q3` (troubleshooting)

The pods of Deployment `api` never become Ready and keep restarting.

- Fix the probes (do not remove them) so that both replicas become Ready.
  - readinessProbe: `httpGet`, path `/`, port 80
  - livenessProbe: `tcpSocket`, port 80
  - Other probe fields (period, thresholds, ...) are up to you.
- Pod `crasher` in the same namespace keeps dying. Write the **last exit
  code** of its container (the number only) to `answers/q3/exit-code.txt`.
  Do not fix `crasher`.

## Question 4 (25%) -- namespace `r01-q4`

1. ConfigMap `app-config`
   - key `LOG_LEVEL`, value `debug`
   - key `app.properties`, whose value is these two lines:

     ```
     cache.size=128
     feature.x=on
     ```
2. Secret `db-cred` (generic): `user=admin`, `password=S3cr3t!`
3. ServiceAccount `app-sa`: must not automount an API token (set this on
   the ServiceAccount).
4. Pod `secure-app`: image `busybox:1.36`, command `sleep 3600`
   - Uses ServiceAccount `app-sa`.
   - Env var `LOG_LEVEL` from key `LOG_LEVEL` of ConfigMap `app-config`.
   - Env var `DB_PASSWORD` from key `password` of Secret `db-cred`.
   - Mount **only** the `app.properties` key of the ConfigMap as
     `/etc/app/app.properties` (`/etc/app` must contain only this file).
   - Runs as UID `1000`, GID `3000`, with `runAsNonRoot: true`.
   - No privilege escalation, read-only root filesystem, all capabilities
     dropped.
   - Requests `cpu: 50m`, `memory: 32Mi` / limits `cpu: 100m`,
     `memory: 64Mi`.

## Question 5 (20%) -- namespace `r01-q5` (includes troubleshooting)

Service `backend-svc` sits in front of Deployment `backend` (nginx, port
80), but requests never reach the backend.

1. Fix `backend-svc` so that `http://backend-svc.r01-q5.svc.cluster.local`
   (port 80) reaches the 2 `backend` pods. Keep the Service name, type
   (ClusterIP), and port 80 unchanged.
2. Create a NetworkPolicy `allow-frontend` that allows ingress to pods
   labeled `app=backend` on **TCP 80 only**, from the two sources below,
   and denies all other ingress.
   - Pods labeled `role=frontend` in the same namespace (`r01-q5`)
   - All pods in namespaces labeled `purpose=monitoring`

   Pods to test with: `r01-q5/frontend` (allowed), `r01-q5-mon/prober`
   (allowed), `r01-q5/intruder` (denied), `r01-q5-ext/frontend` (denied).
