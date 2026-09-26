#!/usr/bin/env bash
# Install kubectl and kind into ~/.local/bin (no sudo), verifying checksums.
# Pin versions with KUBECTL_VERSION=v1.37.1 / KIND_VERSION=v0.33.0.
set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
mkdir -p "$BIN_DIR"

echo "kubectl $KUBECTL_VERSION"
curl -fsSLo kubectl "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
echo "$(curl -fsSL "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl.sha256")  kubectl" | sha256sum -c -
install -m 0755 kubectl "$BIN_DIR/kubectl"

echo "kind $KIND_VERSION"
curl -fsSLo "kind-linux-$ARCH" "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH"
curl -fsSL "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH.sha256sum" | sha256sum -c -
install -m 0755 "kind-linux-$ARCH" "$BIN_DIR/kind"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: add $BIN_DIR to PATH" ;;
esac
"$BIN_DIR/kubectl" version --client
"$BIN_DIR/kind" version
