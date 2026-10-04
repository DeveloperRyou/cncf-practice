# CKAD Mock Exam -- Round 03

- Suggested time: **30 minutes** / 4 questions, 100 points total / passing
  score **66%**
- There is a single context (`kind-cncf`), so no context switching. Work in
  the namespace given for each question.
- File answers go under `answers/qN/` in this directory, at the path given.
- You may use the official docs (kubernetes.io/docs, helm.sh/docs). Don't
  open `grade.sh` before you finish -- it reveals the grading criteria.
- Needs `helm` (`./scripts/install.sh` installs it).

## Before you start

```bash
./scripts/down.sh && ./scripts/up.sh   # fresh cluster
./ckad/round-03/setup.sh               # pre-create resources (re-running resets r03-*)
```

When done, ask the agent to grade round 3.

---

## Question 1 (25%) -- namespace `r03-q1`

Create a Deployment named `app` with 1 replica and pod label `app=app`.

- The pod has one `emptyDir` volume named `logs`.
- Container `app`, image `busybox:1.36`: every 2 seconds appends the line
  `tick` to `/var/log/app/app.log` (the volume is mounted at
  `/var/log/app`), forever.
- A **native sidecar** named `log-shipper` (an init container that keeps
  running alongside the main container), image `busybox:1.36`: mounts the
  same volume **read-only** at `/var/log/app` and follows the file with
  `tail -F /var/log/app/app.log`.

When the pod is running, save the logs of the `log-shipper` container to
`answers/q1/shipper.log`.

## Question 2 (25%) -- namespace `r03-q2`

A Helm chart is in `ckad/round-03/charts/webapp`. Two releases of it are
already installed in `r03-q2`.

1. Uninstall the release `legacy`.
2. Release `api` was upgraded and its new pods never become Ready. Roll it
   back to its last working revision with Helm.
3. Install a new release `shop` from the local chart with
   `replicaCount=2` and `image.tag=1.27-alpine`. Both pods must be Ready.
4. Save the output of `helm history api -n r03-q2` to
   `answers/q2/history.txt`.

## Question 3 (25%) -- namespace `r03-q3` (troubleshooting)

The pod of Deployment `importer` keeps crashing.

1. Before fixing anything, write, from the pod's status:
   - the **exit code** of its last terminated container (the number only)
     to `answers/q3/exit-code.txt`;
   - the **reason** it was terminated, exactly as Kubernetes reports it
     (one word), to `answers/q3/reason.txt`.
2. Save the logs of the **previous** (crashed) container instance to
   `answers/q3/previous.log`.
3. Fix it by changing **only** the ConfigMap `importer-config` (keep its
   existing value; don't edit the Deployment). The pod must then keep
   running.

## Question 4 (25%) -- namespace `r03-q4`

Deployments `web` (pods `app=web`) and `api` (pods `app=api`, container
port named `http`) are running.

1. Create Service `web-svc` (ClusterIP, port 80 -> container port 80) for
   `web`, and Service `api-svc` (ClusterIP, port 8080) for `api` whose
   `targetPort` is the container port **name** `http`.
2. Create a TLS Secret `shop-tls` from `ckad/round-03/q4/tls.crt` and
   `ckad/round-03/q4/tls.key` (created by `setup.sh`).
3. Create Ingress `shop` with ingress class `nginx` for host
   `shop.example.com`, terminating TLS with `shop-tls`:
   - path `/` (Prefix) -> `web-svc:80`
   - path `/api` (Prefix) -> `api-svc:8080`

   No ingress controller is installed; only the object is checked.
