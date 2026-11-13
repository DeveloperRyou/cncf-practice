# CKA 모의고사

killer.sh 형식의 실기 모의고사. 회차당 5문제·약 40분, 난이도 중상.
클러스터는 노드 3대(`kind/cka.yaml`)를 쓴다.
출제·채점 기준은 [`docs/mock-exam.md`](../docs/mock-exam.md)의 CKA 절.

```bash
./scripts/down.sh && KIND_CONFIG=kind/cka.yaml ./scripts/up.sh
./cka/round-01/setup.sh
```

## 회차

점수와 채점 결과는 개인 기록이라 저장소에 올리지 않는다(`.gitignore`).
시험 화면의 회차 목록과 결과 화면에서 본다.

| 회차 | 출제일 |
|---|---|
| [01](round-01/README.md) | 2026-10-15 |
| [02](round-02/README.md) | 2026-10-15 |
| [03](round-03/README.md) | 2026-10-15 |
| [04](round-04/README.md) (복습: killer.sh 오답) | 2026-11-08 |

## 출제 범위 누적

| 영역 | 다룬 주제 (회차) |
|---|---|
| Cluster Architecture, Installation and Configuration | CSR 사용자 인증서, Role/RoleBinding(group), kubeconfig (01); Helm template/install(values로 CRD 제외), CRD·커스텀 리소스, kubectl explain (01); static Pod(비기본 staticPodPath), CRI 런타임 버전 (03); SA RBAC, ClusterRole+RoleBinding, ClusterRoleBinding, 과도한 권한 제거 (03) |
| Workloads and Scheduling | taint/toleration, required node affinity, PriorityClass (02); kubectl top, requests/limits, HPA v2 behavior (02); DaemonSet(control plane 포함), 네이티브 사이드카, DaemonSet maxSurge (03) |
| Services and Networking | Ingress → Gateway API 이전(HTTPS listener, HTTPRoute) (01); NetworkPolicy 중 최소 권한 선택, NodePort (02); named targetPort, TLS Secret, Ingress TLS/path (03) |
| Storage | StorageClass(no-provisioner, WaitForFirstConsumer, 기본 클래스), local PV/PVC 바인딩, readOnly 마운트 (01); Released PV 재사용(claimRef), Deployment PVC 마운트 (02) |
| Troubleshooting | kubelet 장애(config, systemd enable) (01); CoreDNS Corefile, dnsPolicy, hosts 플러그인 (02); kube-scheduler manifest 장애, Service/Pod CIDR (03); Service endpoints 없음 (03) |

복습 회차(04)는 killer.sh CKA-A에서 틀린 주제를 다시 낸 것이라 새 주제는 없다: kubeconfig 추출, kubeadm 인증서 만료·갱신 명령, Helm repo/install(cert-manager)과 ClusterIssuer, Pod 안에서 API 호출, QoS, NetworkPolicy egress, HTTPRoute 헤더 매칭, CoreDNS 도메인 추가, crictl.

아직 안 다룬 것: Kustomize, drain/cordon, PodDisruptionBudget, Pod Security Admission, StatefulSet
volumeClaimTemplates, Gateway API 가중치, 컨테이너 로그(노드
`/var/log/pods`).
