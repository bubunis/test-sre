#!/usr/bin/env bash
# Creates random passwords in ./secrets. Safe to re-run: existing files are kept.
# Usage (from the repo root):  ./scripts/init-secrets.sh
set -euo pipefail

cd "$(dirname "$0")/.."
umask 077
mkdir -p secrets
chmod 700 secrets   # only your user can open the folder on this machine

if [[ ! -f secrets/postgres_password.txt ]]; then
  openssl rand -hex 32 | tr -d '\n' > secrets/postgres_password.txt
  echo "created secrets/postgres_password.txt"
fi

if [[ ! -f secrets/redis_password.txt ]]; then
  openssl rand -hex 32 | tr -d '\n' > secrets/redis_password.txt
  echo "created secrets/redis_password.txt"
fi

# Redis reads its password from a config file, so it never shows in `ps`
printf 'requirepass %s\n' "$(cat secrets/redis_password.txt)" > secrets/redis.conf

# Containers run as their own users (postgres, redis), so the files must be
# readable inside the container. The 700 folder still blocks other host users.
chmod 644 secrets/*

echo "secrets ready in ./secrets"
