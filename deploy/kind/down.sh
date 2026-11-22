#!/usr/bin/env bash
# Deletes the kind cluster and everything in it (including the Postgres volume).
set -euo pipefail
kind delete cluster --name token-service
