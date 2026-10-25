#!/usr/bin/env bash
# Install kubectl, kind and ttyd into ~/.local/bin (no sudo), verifying checksums.
# Pin versions with KUBECTL_VERSION=v1.37.1 / KIND_VERSION=v0.33.0 / TTYD_VERSION=1.7.7.
# Works on Linux (WSL) and macOS. On macOS, Homebrew supplies bash 4+ and jq
# (grade.sh needs both), and ttyd -- which ships no macOS binary -- is built
# from source with TTYD_VERSION ignored (brew's ttyd formula pulls in a python
# build that fails on older Xcode).
set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

KUBECTL_VERSION="${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"
if [ -z "${KIND_VERSION:-}" ]; then
  # Fetch fully before grepping: grep -m1 closing the pipe early makes curl fail under pipefail.
  release_json="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest)"
  KIND_VERSION="$(grep -m1 '"tag_name"' <<<"$release_json" | cut -d'"' -f4)"
fi
if [ "$OS" = linux ] && [ -z "${TTYD_VERSION:-}" ]; then
  release_json="$(curl -fsSL https://api.github.com/repos/tsl0922/ttyd/releases/latest)"
  TTYD_VERSION="$(grep -m1 '"tag_name"' <<<"$release_json" | cut -d'"' -f4)"
fi

# macOS has no sha256sum; shasum -a 256 reads the same "hash  file" format.
sha256_check() {
  if command -v sha256sum >/dev/null; then sha256sum -c -; else shasum -a 256 -c -; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
mkdir -p "$BIN_DIR"

echo "kubectl $KUBECTL_VERSION"
curl -fsSLo kubectl "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl"
echo "$(curl -fsSL "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl.sha256")  kubectl" | sha256_check
install -m 0755 kubectl "$BIN_DIR/kubectl"

echo "kind $KIND_VERSION"
curl -fsSLo "kind-$OS-$ARCH" "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-$OS-$ARCH"
curl -fsSL "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-$OS-$ARCH.sha256sum" | sha256_check
install -m 0755 "kind-$OS-$ARCH" "$BIN_DIR/kind"

# ttyd serves the exam UI's terminal (scripts/exam.sh).
if [ "$OS" = darwin ]; then
  command -v brew >/dev/null || { echo "macOS needs Homebrew (https://brew.sh)" >&2; exit 1; }
  echo "bash, jq + ttyd build deps (Homebrew)"
  # Don't upgrade already-installed deps: on unsupported macOS versions brew
  # rebuilds them from source, and some of those builds fail.
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 brew install bash jq cmake libuv json-c openssl@3
  echo "ttyd 1.7.7 (source build)"
  # libwebsockets 4.3.x doesn't compile against OpenSSL 4, so pin openssl@3.
  H="$(brew --prefix)/opt" SSL="$(brew --prefix)/opt/openssl@3"
  curl -fsSLo lws.tar.gz https://github.com/warmcat/libwebsockets/archive/refs/tags/v4.3.5.tar.gz
  curl -fsSLo ttyd.tar.gz https://github.com/tsl0922/ttyd/archive/refs/tags/1.7.7.tar.gz
  sha256_check <<'SUMS'
87f99ad32803ed325fceac5327aae1f5c1b417d54ee61ad36cffc8df5f5ab276  lws.tar.gz
039dd995229377caee919898b7bd54484accec3bba49c118e2d5cd6ec51e3650  ttyd.tar.gz
SUMS
  tar xzf lws.tar.gz && tar xzf ttyd.tar.gz
  # Static libwebsockets so ttyd doesn't depend on a dylib in this temp dir.
  cmake -S libwebsockets-4.3.5 -B lws-build -DCMAKE_INSTALL_PREFIX="$tmp/prefix" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DLWS_WITH_LIBUV=ON -DLWS_WITH_HTTP2=ON -DLWS_IPV6=ON -DLWS_UNIX_SOCK=ON \
    -DLWS_WITHOUT_TESTAPPS=ON -DLWS_WITH_STATIC=ON -DLWS_WITH_SHARED=OFF \
    -DOPENSSL_ROOT_DIR="$SSL" -DCMAKE_PREFIX_PATH="$H/libuv;$SSL" >/dev/null
  cmake --build lws-build -j "$(sysctl -n hw.ncpu)" >/dev/null
  cmake --install lws-build >/dev/null
  # ttyd links the shared lws target by default; point it at the static one.
  sed -i '' 's/${LIBWEBSOCKETS_LIBRARIES}/websockets/' ttyd-1.7.7/CMakeLists.txt
  cmake -S ttyd-1.7.7 -B ttyd-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DOPENSSL_ROOT_DIR="$SSL" -DCMAKE_PREFIX_PATH="$tmp/prefix;$H/libuv;$H/json-c;$SSL" \
    -DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip_dylibs >/dev/null
  cmake --build ttyd-build -j "$(sysctl -n hw.ncpu)" >/dev/null
  install -m 0755 ttyd-build/ttyd "$BIN_DIR/ttyd"
else
  echo "ttyd $TTYD_VERSION"
  TTYD_ASSET="ttyd.$(uname -m | sed 's/arm64/aarch64/')"
  curl -fsSLo "$TTYD_ASSET" "https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION/$TTYD_ASSET"
  curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION/SHA256SUMS" | grep " $TTYD_ASSET\$" | sha256_check
  install -m 0755 "$TTYD_ASSET" "$BIN_DIR/ttyd"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: add $BIN_DIR to PATH" ;;
esac
"$BIN_DIR/kubectl" version --client
"$BIN_DIR/kind" version
"$BIN_DIR/ttyd" --version
