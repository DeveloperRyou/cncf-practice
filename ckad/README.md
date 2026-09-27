# CKAD 모의고사

killer.sh 형식의 실기 모의고사. 회차당 5문제, 난이도 중상.
출제·채점 기준은 [`docs/mock-exam.md`](../docs/mock-exam.md).

## 회차

점수와 채점 결과는 개인 기록이라 저장소에 올리지 않는다(`.gitignore`).
시험 화면의 회차 목록과 결과 화면에서 본다.

| 회차 | 출제일 |
|---|---|
| [01](round-01/README.md) | 2026-09-27 |

## 출제 범위 누적

| 영역 | 다룬 주제 (회차) |
|---|---|
| Application Design and Build | Job completions/parallelism/backoffLimit, init container, emptyDir (01) |
| Application Deployment | rollout undo, RollingUpdate maxSurge/maxUnavailable, change-cause, rollout history (01) |
| Application Observability and Maintenance | readinessProbe httpGet, livenessProbe tcpSocket, 종료 코드 확인 (01) |
| Application Environment, Configuration and Security | ConfigMap(literal+file), Secret, SA automount, env valueFrom, ConfigMap items 볼륨, securityContext, resources (01) |
| Services and Networking | Service selector/targetPort 트러블슈팅, NetworkPolicy pod+namespace selector·포트 제한 (01) |
