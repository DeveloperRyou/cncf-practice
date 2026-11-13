# CKA Mock Exam -- Round 04 (review round)

- Suggested time: **40 minutes** / 5 questions, 100 points total / passing
  score **66%**
- A review of the topics missed in an earlier killer.sh run. Several
  questions have two independent parts.
- One context (`kind-cncf`) with three nodes: `cncf-control-plane`,
  `cncf-worker`, `cncf-worker2`. Work in the namespace given for each
  question.
- `ssh <node>` opens a shell on a node in the exam terminal (elsewhere:
  `docker exec -it <node> bash`). You are root there; `vim` and `crictl`
  are installed. Files you write while on a node stay on the node, so
  redirect output on the host side where a question names a file under
  `answers/`.
- File answers go under `answers/qN/` in this directory, at the path given.
  Files the setup prepared for you are under `workdir/`.
- You may use the official docs (kubernetes.io/docs, helm.sh/docs,
  gateway-api.sigs.k8s.io). Don't open `grade.sh` before you finish -- it
  reveals the grading criteria.

## Before you start

```bash
./scripts/down.sh && KIND_CONFIG=kind/cka.yaml ./scripts/up.sh   # fresh 3-node cluster
./cka/round-04/setup.sh                                          # pre-create resources (re-running resets the round)
```

When done, ask the agent to grade round 4.

---

## Question 1 (20%)

1. The kubeconfig file `workdir/kubeconfig` is **not** your default one
   (don't copy it over `~/.kube/config`). From it, write:
   - all context names, one per line, to `answers/q1/contexts`
   - the name of the current context to `answers/q1/current-context`
   - the client certificate of user `account-0027`, **base64-decoded**
     (a PEM file), to `answers/q1/cert`
2. Find out how long the `kube-apiserver` server certificate on the control
   plane node is valid, using `openssl`. Write the expiration date to
   `answers/q1/expiration` (any common date format). Also run the `kubeadm`
   command that lists the certificate expirations and make sure it shows
   the same date.
3. Write the `kubeadm` command that would renew **only** the kube-apiserver
   certificate to `answers/q1/renew.sh`. Do not run it.

## Question 2 (15%) -- namespace `cert-manager`

1. Create namespace `cert-manager` and install Helm chart
   `jetstack/cert-manager` into it with `crds.enabled=true`. The release is
   called `cert-manager`. (The chart repository `jetstack` is
   `https://charts.jetstack.io`; it isn't configured on this machine yet.)
2. Update the ClusterIssuer manifest `workdir/cluster-issuer.yaml` to include
   `crlDistributionPoints: ["http://example.com/crl"]` under
   `spec.selfSigned`.
3. Create the ClusterIssuer from that file.

## Question 3 (20%) -- namespaces `r04-q3`, `r04-q3-qos`

1. ServiceAccount `secret-reader` exists in `r04-q3`. Create a Pod
   `api-contact` (image `nginx:1-alpine`) in `r04-q3` that uses it. Exec into
   the Pod and use `curl` to query the Secrets of namespace `r04-q3` from the
   Kubernetes API (you can't use `kubectl` inside the Pod). Save the
   response body to `answers/q3/result.json` **on the host**.
2. Check all Pods in namespace `r04-q3-qos` and find the names of those that
   would probably be terminated first if the node runs out of resources
   (CPU or memory). Write the Pod names to
   `answers/q3/pods-terminated-first.txt`, one per line.

## Question 4 (20%) -- namespaces `r04-q4-np`, `r04-q4-gw`

1. A hacked `backend-*` Pod must not be able to reach the rest of the
   cluster. In `r04-q4-np`, create NetworkPolicy `np-backend` so that the
   Pods labelled `app=backend` may only connect out to:
   - `app=db1` Pods on port `1111`
   - `app=db2` Pods on port `2222`

   Use the `app` Pod labels. All Pods run plain nginx, so you can test with
   `kubectl -n r04-q4-np exec <pod> -- wget -qO- -T 3 <pod-ip>:<port>`.
   Connections from `backend` to `vault` on port `3333` must stop working.
2. In `r04-q4-gw`, Gateway `main` already exists and the old Ingress is at
   `workdir/ingress.yaml`. Create HTTPRoute `traffic-director` attached to
   `main` that replicates the Ingress routes, and additionally path `/auto`
   (prefix) which goes to `web-mobile` when the `User-Agent` header is
   exactly `mobile`, and to `web-desktop` otherwise. All backends use port
   `80`.

## Question 5 (25%) -- namespace `r04-q5`

1. CoreDNS: save the current `coredns` ConfigMap (`kube-system`) as YAML to
   `answers/q5/coredns-backup.yaml`. Then change the CoreDNS configuration
   so that `kubernetes.default.svc.custom-domain` resolves (to the same IP
   as `kubernetes.default.svc.cluster.local`) while the `cluster.local`
   names keep working. Make sure CoreDNS is serving the new configuration.
2. Create Pod `tigers-reunite` (image `httpd:2-alpine`, labels `pod=container`
   and `container=pod`) in `r04-q5`. Find the node it runs on and its
   containerd container. Using `crictl` on that node:
   - write the container ID (first line) and `info.runtimeType` (second
     line) to `answers/q5/pod-container.txt`
   - write the container's logs to `answers/q5/pod-container.log`
