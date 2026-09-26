# ckad-practice

CKAD 연습용 로컬 쿠버네티스 환경. WSL2(Ubuntu) + Docker Desktop 위에
[kind](https://kind.sigs.k8s.io/)로 단일 노드 클러스터를 띄운다.

## 환경

| 항목 | 버전 |
|---|---|
| WSL | 2.7.14 |
| Linux 커널 | 6.18.33.2-microsoft-standard-WSL2 |
| 배포판 | Ubuntu 22.04 |
| Docker Desktop | 4.89.0 |
| cgroup | v2 전용 |
| kubectl | v1.37.1 |
| kind | v0.33.0 (노드 이미지 `kindest/node:v1.37.0`) |

## 사전 준비

1. **WSL을 cgroup v2 전용으로 설정한다.** kubelet 1.35+는 cgroup v1
   호스트에서 기동하지 않는다. `C:\Users\<사용자>\.wslconfig`:

   ```ini
   [wsl2]
   kernelCommandLine = cgroup_no_v1=all
   ```

   PowerShell에서 `wsl --update` → `wsl --shutdown` 후 WSL을 다시 열고
   확인한다.

   ```bash
   stat -fc %T /sys/fs/cgroup              # cgroup2fs
   docker info --format '{{.CgroupVersion}}' # 2
   ```

2. **Docker Desktop**을 실행하고 Settings → Resources → WSL integration에서
   해당 배포판을 켠다.
3. `~/.local/bin`이 `PATH`에 있어야 한다(Ubuntu 기본 `.profile`이 추가).
   sudo는 필요 없다.

## 클러스터 띄우기

```bash
./scripts/install.sh   # kubectl, kind를 ~/.local/bin에 설치 (체크섬 검증)
./scripts/up.sh        # 클러스터 생성 + 파드를 띄울 수 있을 때까지 대기
```

`up.sh`는 `kind/ckad.yaml`로 `ckad` 클러스터를 만들고(이미 있으면 건너뜀),
kubectl 컨텍스트를 `kind-ckad`로 바꾼 뒤 노드가 Ready이고 default
ServiceAccount가 생길 때까지 기다린다.

동작 확인:

```bash
kubectl get nodes
kubectl run nginx --image=nginx --restart=Never
kubectl wait --for=condition=Ready pod/nginx
kubectl delete pod nginx
```

삭제 / 재생성:

```bash
./scripts/down.sh && ./scripts/up.sh   # 1분 안에 깨끗한 클러스터
```

옵션:

- `KUBECTL_VERSION=v1.37.1 KIND_VERSION=v0.33.0 ./scripts/install.sh` --
  버전 고정 (생략하면 최신 stable)
- `CLUSTER_NAME=foo ./scripts/up.sh` -- 클러스터 이름 (기본 `ckad`)

## 알아둘 것

- 노드가 Docker 컨테이너라 Docker Desktop이 꺼지면 클러스터도 멈춘다.
  다시 켜면 올라온다.
- `LoadBalancer` Service는 외부 IP를 받지 못한다.
  `kubectl port-forward`나 `NodePort`로 접근한다.
