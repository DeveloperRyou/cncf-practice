# CKAD 모의고사

killer.sh 형식의 실기 모의고사. 회차당 3~4문제·약 30분, 난이도 중상
(round-01·02는 5문제·40분).
출제·채점 기준은 [`docs/mock-exam.md`](../docs/mock-exam.md).

## 회차

점수와 채점 결과는 개인 기록이라 저장소에 올리지 않는다(`.gitignore`).
시험 화면의 회차 목록과 결과 화면에서 본다.

| 회차 | 출제일 |
|---|---|
| [01](round-01/README.md) | 2026-09-27 |
| [02](round-02/README.md) | 2026-10-01 |
| [03](round-03/README.md) | 2026-10-04 |
| [04](round-04/README.md) | 2026-10-04 |
| [05](round-05/README.md) | 2026-10-04 |

## 출제 범위 누적

| 영역 | 다룬 주제 (회차) |
|---|---|
| Application Design and Build | Job completions/parallelism/backoffLimit, init container, emptyDir (01); CronJob schedule/concurrencyPolicy/history, activeDeadlineSeconds, Job from CronJob (02); 네이티브 사이드카 (03); PVC, Downward API, 읽기 전용 마운트 (04); Job+init+emptyDir+activeDeadlineSeconds 재출제 (05) |
| Application Deployment | rollout undo, RollingUpdate maxSurge/maxUnavailable, change-cause, rollout history (01); canary(라벨 기반), scale (02); Helm uninstall/rollback/install --set (03); Kustomize overlay (04); readinessProbe로 멈춘 rollout, change-cause 재출제 (05) |
| Application Observability and Maintenance | readinessProbe httpGet, livenessProbe tcpSocket, 종료 코드 확인 (01); 시작 못 하는 컨테이너(command) 트러블슈팅, OOMKilled·memory limit (02); exit code/termination reason, logs --previous (03); readinessProbe 수정 (05) |
| Application Environment, Configuration and Security | ConfigMap(literal+file), Secret, SA automount, env valueFrom, ConfigMap items 볼륨, securityContext, resources (01); ResourceQuota+LimitRange, RBAC Role/RoleBinding, auth can-i, Downward API env, Secret 볼륨 defaultMode (02); RBAC(apps 그룹), can-i, 파드 template SA/automount (04); Quota+LimitRange(max), SA automount, securityContext 재출제 (05) |
| Services and Networking | Service selector/targetPort 트러블슈팅, NetworkPolicy pod+namespace selector·포트 제한 (01); ClusterIP port/targetPort, NodePort, Ingress path, NetworkPolicy egress+DNS (02); named targetPort, TLS Secret, Ingress TLS/Prefix (03); NetworkPolicy default-deny + OR/AND 트러블슈팅 (04); egress+DNS, Service port vs 파드 port 재출제 (05) |
