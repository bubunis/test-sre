# Sourced by the other scripts: works out where we are running.
#   OS        darwin | linux
#   ARCH      amd64 | arm64          (this machine's CPU, for downloading tools)
#   NODE_ARCH amd64 | arm64          (Docker's CPU = the kind node's CPU, for building images)
#   IN_CI     1 on GitHub Actions (or any CI that sets CI=true), else 0

case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux)  OS=linux ;;
  *) echo "unsupported OS: $(uname -s) (use macOS, Linux or WSL2)"; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "unsupported CPU: $(uname -m)"; exit 1 ;;
esac

# Docker can run a different CPU than the host (e.g. a Linux VM, or Rosetta on
# Apple Silicon). The kind node runs on Docker, so images must match Docker.
case "$(docker info --format '{{.Architecture}}' 2>/dev/null)" in
  x86_64|amd64)  NODE_ARCH=amd64 ;;
  aarch64|arm64) NODE_ARCH=arm64 ;;
  "") NODE_ARCH="" ;;   # Docker not running; up.sh stops on this
  *) NODE_ARCH=$ARCH ;;
esac

IN_CI=0
[[ "${CI:-}" == "true" || -n "${GITHUB_ACTIONS:-}" ]] && IN_CI=1

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi        # macOS
}

port_in_use() {
  if command -v lsof >/dev/null; then lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else ss -ltn "sport = :$1" 2>/dev/null | grep -q LISTEN; fi   # Linux without lsof
}

describe_platform() {
  local chip="$ARCH"
  [[ $OS == darwin && $ARCH == arm64 ]] && chip="arm64 (Apple Silicon)"
  [[ $OS == darwin && $ARCH == amd64 ]] && chip="amd64 (Intel Mac)"
  echo "platform: $OS / $chip, Docker: linux/${NODE_ARCH:-not running}, CI: $([[ $IN_CI == 1 ]] && echo yes || echo no)"
}
