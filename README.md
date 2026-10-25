# cncf-practice

CNCF 자격증(CKAD 등) 실기 연습용 저장소. WSL2(Ubuntu) 또는 macOS의 Docker
Desktop 위에 [kind](https://kind.sigs.k8s.io/)로 단일 노드 클러스터를 띄우고, AI 에이전트가
killer.sh 형식의 모의고사를 출제·채점한다.

| 경로 | 내용 |
|---|---|
| `scripts/`, `kind/` | 로컬 클러스터 설치·생성 |
| [`ckad/`](ckad/) | CKAD 모의고사 (회차별 디렉터리) |
| [`docs/mock-exam.md`](docs/mock-exam.md) | 모의고사 출제·풀이·채점 기준 |

## 환경

검증한 환경. 아래 표는 WSL 기준이고, macOS는 [macOS](#macos) 절을 본다.

| 항목 | 버전 |
|---|---|
| WSL | 2.7.14 |
| Linux 커널 | 6.18.33.2-microsoft-standard-WSL2 |
| 배포판 | Ubuntu 22.04 |
| Docker Desktop | 4.89.0 |
| cgroup | v2 전용 |
| kubectl | v1.37.1 |
| kind | v0.33.0 (노드 이미지 `kindest/node:v1.37.0`) |
| ttyd | 1.7.7 |

## 사전 준비

### WSL

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

### macOS

macOS 14.5(Apple Silicon) + Docker Desktop 29.9.2에서 검증했다. Docker
Desktop의 리눅스 VM이 cgroup v2라 WSL 같은 설정은 필요 없다.

1. **Docker Desktop**을 설치하고 실행한다.
2. **[Homebrew](https://brew.sh)**가 있어야 한다. `install.sh`가 brew로
   다음을 설치한다.
   - `bash`(4+)와 `jq`: `grade.sh`가 연관 배열과 jq를 쓴다. macOS 기본
     bash는 3.2라서 `exam.sh`가 brew bin을 `PATH` 앞에 넣고 실행한다.
     시험 화면 밖에서 `grade.sh`를 직접 돌리려면 brew bash가 `PATH`에서
     `/bin/bash`보다 앞에 있어야 한다.
   - ttyd 빌드 의존성(`cmake`, `libuv`, `json-c`, `openssl@3`): ttyd는
     macOS 바이너리를 배포하지 않고, brew의 ttyd formula는 Homebrew가
     지원을 줄인 macOS 버전(Tier 3)에서 의존성 빌드가 실패한다. 그래서
     `install.sh`가 libwebsockets 4.3.5(정적)와 ttyd 1.7.7 소스를 받아
     체크섬을 검증한 뒤 직접 빌드한다. `TTYD_VERSION`은 무시된다.
   - 이미 설치된 brew 패키지는 업그레이드하지 않는다
     (`HOMEBREW_NO_INSTALL_UPGRADE=1`). Tier 3 macOS에서는 업그레이드가
     소스 빌드로 바뀌어 실패할 수 있다.
3. `~/.local/bin`을 `PATH`에 추가한다(`~/.zshrc`에
   `export PATH="$HOME/.local/bin:$PATH"`).

## 클러스터 띄우기

```bash
./scripts/install.sh   # kubectl, kind, ttyd를 ~/.local/bin에 설치 (체크섬 검증, macOS는 ttyd 소스 빌드)
./scripts/up.sh        # 클러스터 생성 + 파드를 띄울 수 있을 때까지 대기
```

`up.sh`는 `kind/cluster.yaml`로 `cncf` 클러스터를 만들고(이미 있으면 건너뜀),
kubectl 컨텍스트를 `kind-cncf`로 바꾼 뒤 노드가 Ready이고 default
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

- `KUBECTL_VERSION=v1.37.1 KIND_VERSION=v0.33.0 TTYD_VERSION=1.7.7 ./scripts/install.sh` --
  버전 고정 (생략하면 최신 stable)
- `CLUSTER_NAME=foo ./scripts/up.sh` -- 클러스터 이름 (기본 `cncf`)

## 시험 화면 (killer.sh 스타일)

```bash
./scripts/exam.sh    # http://localhost:8000/ 을 브라우저(WSL이면 Windows 쪽)에서 연다
```

1. **환경 확인** -- 터미널(ttyd), Docker, kind, kubectl이 준비됐는지 확인.
2. **회차 선택** -- `*/round-*/README.md`를 찾아 목록을 보여 준다.
3. **환경 준비** -- 버튼 한 번으로 `down.sh` → `up.sh` → `<회차>/setup.sh`를
   돌리고 로그를 보여 준다.
4. 준비가 끝나야 **Start exam**이 켜진다.
5. 시작하면 타이머가 돌고, 왼쪽에 문제(번호 탭, 플래그, 인라인 코드 클릭 시
   복사), 오른쪽에 bash 터미널(WSL bash, macOS는 brew bash)(`k` 별칭·자동완성, 저장소 루트에서
   시작)이 뜬다.
6. **End exam**을 누르면 `<회차>/finished.json`에 종료를 기록하고
   `grade.sh`를 돌려 `<회차>/grade.json`에 저장한 뒤, 결과 화면(총점·합격
   여부, 영역별 점수, 문제별 주제·채점 항목)을 보여 준다. **Re-grade**로
   다시 채점할 수 있고, 해설·모범 풀이는 에이전트에게 요청한다.

회차 목록에서 푼 회차는 점수와 함께 표시되고, 누르면 재시험을 준비할 수
있다(환경 준비 화면에서 지난 결과도 볼 수 있다). `down.sh`는 클러스터만
지우고 `answers/` 파일은 남기므로, 환경 준비가 이전 시도의 답안과 결과를
`<회차>/attempts/<시각>/`로 옮기고 시작한다.

- 두 서버 모두 `127.0.0.1`에만 바인딩한다. 같은 PC의 브라우저(WSL이면
  localhost 포워딩으로 Windows 브라우저)에서만 열리고, 네트워크의 다른
  기기에서는 안 열린다.
- ttyd는 `-O`로 다른 origin의 웹소켓 연결을 거부하고, 준비 API는 정해진
  스크립트만 돌리며 커스텀 헤더 없는 요청을 거부한다. 브라우저에 열린 다른
  사이트가 터미널이나 클러스터를 건드릴 수 없다.
- 웹서버는 UI와 문제지(`README.md`)만 내보낸다. `grade.sh` 등은 404.
  외부 도메인으로 `localhost`를 가리키는 요청(DNS rebinding)도 거부한다.
- 포트는 `WEB_PORT`, `TERM_PORT`로 바꾼다 (기본 8000, 7681).

### 배포 (Cloudflare Workers)

<https://cncf-practice.developerryou.workers.dev/>

`exam/web/`만 정적 사이트로 올리고, 문제지·클러스터·터미널은 각자 로컬
클론의 `./scripts/exam.sh`에 붙는다. 배포된 페이지의 환경 확인 화면이 로컬
서버가 없으면 clone/install/실행 방법을, 클론이 upstream보다 뒤처지면
`git pull`을 안내한다.

- `v*` 태그(릴리스)를 push하면 GitHub Actions가 `wrangler deploy`로
  배포한다(`wrangler.jsonc`, 저장소 시크릿 `CLOUDFLARE_API_TOKEN` 필요).
- 로컬 서버는 `EXAM_ORIGINS`(쉼표 구분, 기본
  `https://cncf-practice.developerryou.workers.dev`)에 있는 origin의 요청만 받는다. 다른
  도메인에 배포하면 `EXAM_ORIGINS=https://<도메인> ./scripts/exam.sh`.
- Chrome/Edge는 공개 사이트가 localhost에 접근할 때 "로컬 네트워크 접근"
  권한을 한 번 묻는다. 허용해야 한다. Safari는 https 페이지에서
  `http://localhost`를 막으므로 지원하지 않는다.

## 알아둘 것

- 노드가 Docker 컨테이너라 Docker Desktop이 꺼지면 클러스터도 멈춘다.
  다시 켜면 올라온다.
- `LoadBalancer` Service는 외부 IP를 받지 못한다.
  `kubectl port-forward`나 `NodePort`로 접근한다.
