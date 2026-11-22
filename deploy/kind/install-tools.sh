#!/usr/bin/env bash
# Installs pinned versions of kind, kubectl and helm for this OS and CPU.
# Same versions on a Mac and in CI, and every download is checked against
# its published SHA-256.
#
#   ./deploy/kind/install-tools.sh              # install only what's missing
#   FORCE=1 ./deploy/kind/install-tools.sh      # replace with the pinned versions
#
# In CI it always installs the pinned versions (runner images ship their own,
# which change without notice).
set -euo pipefail
cd "$(dirname "$0")"
source ./platform.sh

KIND_VERSION=v0.26.0
KUBECTL_VERSION=v1.32.0
HELM_VERSION=v3.16.4
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

[[ $IN_CI == 1 ]] && FORCE=1
mkdir -p "$BIN_DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
describe_platform

need() { [[ "${FORCE:-0}" == 1 ]] || ! command -v "$1" >/dev/null; }

verify() {  # file expected-hash
  local got; got=$(sha256 "$1")
  [[ "$got" == "$2" ]] || { echo "checksum mismatch for $1"; exit 1; }
}

if need kind; then
  url="https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-$OS-$ARCH"
  curl -fsSLo "$TMP/kind" "$url"
  verify "$TMP/kind" "$(curl -fsSL "$url.sha256sum" | awk '{print $1}')"
  install -m 0755 "$TMP/kind" "$BIN_DIR/kind"
  echo "installed kind $KIND_VERSION"
fi

if need kubectl; then
  url="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl"
  curl -fsSLo "$TMP/kubectl" "$url"
  verify "$TMP/kubectl" "$(curl -fsSL "$url.sha256" | awk '{print $1}')"
  install -m 0755 "$TMP/kubectl" "$BIN_DIR/kubectl"
  echo "installed kubectl $KUBECTL_VERSION"
fi

if need helm; then
  file="helm-$HELM_VERSION-$OS-$ARCH.tar.gz"
  curl -fsSLo "$TMP/$file" "https://get.helm.sh/$file"
  verify "$TMP/$file" "$(curl -fsSL "https://get.helm.sh/$file.sha256sum" | awk '{print $1}')"
  tar -xzf "$TMP/$file" -C "$TMP"
  install -m 0755 "$TMP/$OS-$ARCH/helm" "$BIN_DIR/helm"
  echo "installed helm $HELM_VERSION"
fi

# Put BIN_DIR on PATH: for the next CI steps, or tell the user
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$BIN_DIR" >> "$GITHUB_PATH"
elif [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "add to your shell profile:  export PATH=\"$BIN_DIR:\$PATH\""
fi
export PATH="$BIN_DIR:$PATH"
kind version; kubectl version --client | head -1; helm version --short
