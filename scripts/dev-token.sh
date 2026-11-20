#!/usr/bin/env bash
# DEV/CI ONLY: print a signed test token for calling POST /token.
# Usage (from the repo root):
#   TOKEN=$(bash scripts/dev-token.sh)                          # valid token
#   TOKEN=$(bash scripts/dev-token.sh login-service profile)    # wrong scope  -> 403
#   TOKEN=$(bash scripts/dev-token.sh login-service token:mint -120) # expired -> 401
#   (use more than -30: the API accepts tokens up to 30 s past expiry for clock skew)
set -euo pipefail
cd "$(dirname "$0")/.."

# Run as your own user: the image runs as uid 10001, which can't read your private key (mode 600)
docker compose run --rm --no-deps -T --user "$(id -u):$(id -g)" \
  -v "$PWD/secrets/jwt_dev_private.pem:/run/dev/jwt.key:ro" \
  -v "$PWD/scripts/dev_token.py:/run/dev/dev_token.py:ro" \
  python-service python /run/dev/dev_token.py "${1:-login-service}" "${2:-token:mint}" "${3:-300}"
