# 모의고사 운영 가이드

AI 에이전트가 모의고사를 출제하고, 사용자가 로컬 클러스터에서 풀어 답을
제출하면, 에이전트가 채점한다. 형식은 [killer.sh](https://killer.sh/)
시뮬레이터를 따른다. 이 문서는 에이전트가 출제·채점할 때 따르는 기준이다.

## 요구 사항

- **형식**: killer.sh처럼 실제 클러스터에서 작업하는 실기형. 객관식·서술형
  없음.
- **난이도**: 중상. 한 문제가 개념 2~3개를 엮는 다단계 작업
  (예: ConfigMap + 볼륨 마운트 + readinessProbe를 한 Deployment에).
  단순 `kubectl run` 한 줄로 끝나는 문제는 내지 않는다.
- **분량**: 1회차 = 5문제.
- **구성**: 자격증별 디렉터리(`ckad/`, 이후 `cka/` 등) 아래 회차별 디렉터리.

## 디렉터리 구조

```
<cert>/                     # ckad, cka, ...
  README.md                 # 회차 목록, 출제 범위 누적 현황
  round-01/
    README.md               # 문제지 (사용자가 보는 유일한 파일)
    setup.sh                # 문제 풀기 전 사전 리소스 생성 (멱등)
    grade.sh                # 자동 채점 스크립트
    answers/                # 사용자가 파일로 제출하는 답
    result.md               # 채점 결과 (채점 후 생성)
  round-02/
  ...
```

## 문제지 형식 (`round-NN/README.md`)

문제지는 실제 시험처럼 **영어로** 쓴다. 문제마다 아래 항목을 둔다.

- **번호와 배점**: 문제별 가중치(%). 5문제 합계 100.
- **네임스페이스**: 작업할 네임스페이스. 문제끼리 겹치지 않게 한다
  (예: `r01-q1`). 클러스터는 kind 단일 컨텍스트라 killer.sh의
  `kubectl config use-context` 단계는 생략한다.
- **과제**: 만들 리소스, 이름, 이미지, 값 등을 채점 가능할 만큼 정확히.
  모호하면 채점이 안 되니 이름·라벨·포트·경로는 모두 지정한다.
- **파일 제출**: 명령 출력이나 매니페스트를 파일로 내는 문제는 경로를
  `answers/qN/<파일>`로 지정한다 (killer.sh의 `/opt/course/N/...`에 해당).

문제지 머리에는 권장 제한 시간(5문제 기준 40분), 시작 전 절차, 합격선
(66%, CKAD와 동일)을 적는다.

## 출제 기준

- CKAD 커리큘럼 5개 영역에서 고르게 낸다.
  - Application Design and Build (20%)
  - Application Deployment (20%)
  - Application Observability and Maintenance (15%)
  - Application Environment, Configuration and Security (25%)
  - Services and Networking (20%)
- 이전 회차와 같은 조합을 반복하지 않는다. `<cert>/README.md`의 누적
  현황을 보고 덜 다룬 주제를 우선한다.
- 로컬 kind 클러스터에서 풀 수 있는 것만 낸다. `LoadBalancer` 외부 IP,
  클라우드 스토리지 등 kind에서 안 되는 기능은 피한다. NetworkPolicy는
  kind 기본 CNI(kindnet)가 적용하는 범위에서만 낸다.
- 필요한 이미지는 공개 이미지(`nginx`, `busybox`, `redis` 등)만 쓴다.
- 망가진 리소스를 고치는 트러블슈팅형을 회차마다 1문제 이상 넣는다.
  이 경우 `setup.sh`가 망가진 상태를 미리 만든다.
- 출제 시 정답·해설은 저장소에 쓰지 않는다. 사용자가 문제를 풀기 전에
  답을 볼 수 없어야 한다. `grade.sh`는 채점 조건이 드러나므로 사용자는
  풀기 전에 열지 않는다(문제지에 명시).

## 풀이 절차 (사용자)

```bash
./scripts/down.sh && ./scripts/up.sh     # 깨끗한 클러스터
./ckad/round-01/setup.sh                 # 사전 리소스 생성
# ckad/round-01/README.md를 보며 풀이, 파일 답은 answers/qN/에
```

다 풀면 에이전트에게 "1회차 채점해줘"라고 요청한다.

## 채점 (에이전트)

1. `grade.sh`를 실행한다. 문제별로 클러스터 상태(리소스 존재, spec 값,
   파드 Ready 여부 등)와 `answers/` 파일을 검사해 항목별 통과/실패를
   출력한다. 부분 점수는 항목 단위로 준다.
2. 스크립트가 판단하기 어려운 부분(매니페스트 작성 방식, 불필요한
   리소스 등)은 에이전트가 클러스터와 답안 파일을 직접 보고 보완한다.
3. `result.md`를 쓴다: 문제별 점수와 총점, 합격 여부, 틀린 항목의 원인,
   모범 풀이(명령/매니페스트), 관련 공식 문서 링크.
4. `<cert>/README.md`의 회차 목록에 점수를 기록한다.
