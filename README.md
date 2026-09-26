# ckad-practice

CKAD 연습용 로컬 쿠버네티스 환경. WSL2(Ubuntu) + Docker Desktop 위에
[kind](https://kind.sigs.k8s.io/)로 단일 노드 클러스터를 띄운다.

## 요구 사항

- WSL2 (Ubuntu)
- Docker Desktop, Settings → Resources → WSL integration에서 해당 배포판 켜기
- `~/.local/bin`이 `PATH`에 있을 것 (Ubuntu 기본 `.profile`이 추가해 줌)

sudo는 필요 없다.

## 사용법

```bash
./scripts/install.sh   # kubectl, kind를 ~/.local/bin에 설치 (체크섬 검증)
./scripts/up.sh        # 클러스터 생성 + 파드를 띄울 수 있을 때까지 대기
./scripts/down.sh      # 클러스터 삭제
```

버전 고정: `KUBECTL_VERSION=v1.37.1 KIND_VERSION=v0.33.0 ./scripts/install.sh`
(생략하면 최신 stable). 클러스터 이름은 `CLUSTER_NAME`(기본 `ckad`),
kubectl 컨텍스트는 `kind-ckad`.

확인:

```bash
kubectl run nginx --image=nginx --restart=Never
kubectl wait --for=condition=Ready pod/nginx
kubectl delete pod nginx
```

## 알아둘 것

- **cgroup v1**: Docker Desktop의 WSL2 VM은 cgroup v1이고, kubelet 1.35+는
  기본값으로 cgroup v1에서 기동을 거부한다(`kubelet is configured to not run
  on a host using cgroup v1`). `kind/ckad.yaml`의 `failCgroupV1: false`
  패치가 이걸 끈다. 설정 없이 `kind create cluster`를 하면 control-plane
  단계에서 실패한다.
- **Docker Desktop 의존**: 노드가 Docker 컨테이너라 Docker Desktop이 꺼지면
  클러스터도 멈춘다. 다시 켜면 올라온다.
- **LoadBalancer 없음**: `LoadBalancer` Service는 외부 IP를 못 받는다.
  `kubectl port-forward`나 `NodePort`로 접근한다.
- 망가지면 `down.sh` → `up.sh`로 1분 안에 새 클러스터.
