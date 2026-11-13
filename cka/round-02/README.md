# CKA Mock Exam -- Round 02

- Suggested time: **40 minutes** / 5 questions, 100 points total / passing
  score **66%**
- One context (`kind-cncf`) with three nodes: `cncf-control-plane`,
  `cncf-worker`, `cncf-worker2`. Work in the namespace given for each
  question.
- `ssh <node>` opens a shell on a node in the exam terminal (elsewhere:
  `docker exec -it <node> bash`). You are root there; `vim` is installed.
- File answers go under `answers/qN/` in this directory, at the path given.
  Files the setup prepared for you are under `workdir/`.
- You may use the official docs (kubernetes.io/docs). Don't open
  `grade.sh` before you finish -- it reveals the grading criteria.

## Before you start

```bash
./scripts/down.sh && KIND_CONFIG=kind/cka.yaml ./scripts/up.sh   # fresh 3-node cluster
./cka/round-02/setup.sh                                          # pre-create resources (re-running resets the round)
```

When done, ask the agent to grade round 2.

---

## Question 1 (20%) -- namespace `r02-q1`

Node `cncf-worker` is to be dedicated to operations workloads.

1. Taint `cncf-worker` with key `dedicated`, value `ops`, effect
   `NoSchedule`, and label it `tier=ops`.
2. Create PriorityClass `ops-critical` whose value is exactly **one less**
   than the highest value among the PriorityClasses that are **not**
   built in (`system-*` don't count). It must not be the global default.
3. Change the existing Deployment `ops-agent` so that its pods
   - run **only** on nodes labeled `tier=ops` (a hard requirement, using
     node affinity),
   - tolerate the taint from step 1,
   - use PriorityClass `ops-critical`.

   Both replicas must be Running on `cncf-worker`.

## Question 2 (20%) -- namespace `r02-q2` (troubleshooting)

Pod `client` can't resolve Service `api` in its namespace. Pod `dns-probe`
is a helper you may use for testing; don't delete it.

1. Fix whatever is broken so that **any** pod using the cluster DNS
   resolves `api.r02-q2.svc.cluster.local`, and pod `client` (recreate it
   if you must, same name, image and command) resolves the short name
   `api`.
2. Make the cluster DNS also answer `legacy.internal` with the address
   `172.30.0.10` for every pod, without breaking anything else it resolves.

## Question 3 (20%) -- namespace `r02-q3`

metrics-server is installed.

1. Of the pods labeled `app=ingest` in `r02-q3`, write the name of the one
   that currently uses the most CPU to `answers/q3/top-pod.txt` (just the
   name).
2. Give the container of Deployment `api` requests of `100m` CPU and
   `64Mi` memory, and a CPU limit of `200m`.
3. Create a HorizontalPodAutoscaler `api` (`autoscaling/v2`) for that
   Deployment: **2** to **6** replicas, target average CPU utilization
   **70%**. When scaling down, it must use a stabilization window of
   **120 seconds** and remove at most **1 pod per 60 seconds**.

## Question 4 (20%) -- namespace `r02-q4`

Deployment `backend` (pods `app=backend`) serves HTTP on port 80. Only the
pods labeled `app=frontend` **in `r02-q4`** may reach it, and only on TCP
port 80. Nothing else is allowed in -- not pod `other`, and not the
`app=frontend` pod in namespace `r02-q4-ext`.

1. Among the three NetworkPolicies in `workdir/netpol/`, apply in `r02-q4`
   the one that meets that requirement and is the **least permissive**.
   Don't modify it and don't apply the others.
2. Expose `backend` with Service `backend` of type `NodePort`: port `80`,
   target port `80`, node port `30080`.

## Question 5 (20%) -- namespace `r02-q5` (storage)

The database's PersistentVolumeClaim was deleted by mistake. Its
PersistentVolume `mariadb-pv` was retained, with the data still on it.

1. Create PersistentVolumeClaim `mariadb` in `r02-q5` (access mode
   `ReadWriteOnce`, `250Mi`) that binds to `mariadb-pv`. Keep the PV's
   reclaim policy and data; don't delete or recreate the PV.
2. `workdir/mariadb.yaml` is the database's Deployment. Edit it to mount
   the claim `mariadb` at `/var/lib/mysql`, then apply it. Deployment
   `mariadb` must be ready and must see the existing data.
