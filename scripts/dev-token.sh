#!/usr/bin/env bash
# DEV/CI ONLY: print a signed test token for calling POST /token.
# Usage (from the repo root):
#   TOKEN=$(bash scripts/dev-token.sh)                          # valid token
#   TOKEN=$(bash scripts/dev-token.sh login-service profile)    # wrong scope  -> 403
#   TOKEN=$(bash scripts/dev-token.sh login-service token:mint -10)  # expired -> 401
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose run --rm --no-deps -T \
  -v "$PWD/secrets/jwt_dev_private.pem:/run/dev/jwt.key:ro" \
  -v "$PWD/scripts/dev_token.py:/run/dev/dev_token.py:ro" \
  python-service python /run/dev/dev_token.py "${1:-login-service}" "${2:-token:mint}" "${3:-300}"
