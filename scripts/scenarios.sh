#!/usr/bin/env bash
# DEV/TEST ONLY: generates traffic, attacks and failures so the Grafana
# dashboards have realistic logs, metrics and traces to show.
#
# It calls http://localhost:8000 and may STOP and START local containers
# (redis, golang-service, postgres). Anything it stops is started again,
# also when you press Ctrl+C. Each run is marked on the dashboards as a
# purple "Test scenarios" annotation.
#
# Usage (from the repo root):  bash scripts/scenarios.sh <scenario> [seconds]
#   baseline         realistic mixed traffic: 85% valid, 10% unknown users, 5% bad auth  (120 s)
#   unknown-users    valid callers asking for users that do not exist -> 404              (60 s)
#   auth-attack      missing / garbage / expired / wrong-scope JWTs -> 401 and 403         (60 s)
#   spike            short burst of high-concurrency valid traffic                         (30 s)
#   ttl-abuse        calls the Go service directly with invalid token lifetimes -> rejected
#   redis-outage     stops Redis while traffic runs -> Go errors, API 5xx                  (45 s down)
#   token-outage     stops the Go token service -> API 5xx, scrape DOWN                    (45 s down)
#   db-outage        stops Postgres -> API 5xx                                             (45 s down)
#   all              runs everything above in order (about 12 minutes)
set -eo pipefail
cd "$(dirname "$0")/.."

API="${API:-http://localhost:8000}"
GRAFANA="${GRAFANA:-http://127.0.0.1:3000}"
DEV_TOKEN="${DEV_TOKEN:-bash scripts/dev-token.sh}"
TOKDIR="$(mktemp -d)"
RESULTS="$TOKDIR/results"
STOPPED=""
export API TOKDIR

cleanup() {
  if [ -n "$STOPPED" ]; then
    echo "Restoring $STOPPED ..."
    docker compose start "$STOPPED" >/dev/null || true
    STOPPED=""
  fi
  jobs -p | xargs kill 2>/dev/null || true
  rm -rf "$TOKDIR"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

say()    { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
now_ms() { echo $(( $(date +%s) * 1000 )); }
pick()   { shift $(( RANDOM % $# )); echo "$1"; }

need_api() {
  curl -sf --max-time 5 "$API/health" >/dev/null || {
    echo "API not reachable at $API. Start the stack first: docker compose up -d"; exit 1; }
}

# ---- dev JWTs (created once per run, reused by every request) ----
make_token() {  # make_token <name> <client_id> <scope> <ttl_seconds>
  $DEV_TOKEN "$2" "$3" "$4" 2>/dev/null > "$TOKDIR/$1"
  [ -s "$TOKDIR/$1" ] || { echo "Could not create dev token '$1' (is the stack built?)"; exit 1; }
}
prepare_tokens() {
  [ -s "$TOKDIR/login" ] && return 0
  say "Creating dev JWTs for 3 clients (takes a few seconds)..."
  make_token login    login-service    token:mint 3600
  make_token admin    admin-console    token:mint 3600
  make_token research research-portal  token:mint 3600
  make_token badscope login-service    profile    3600
  make_token expired  login-service    token:mint -120
}

# ---- one HTTP request; prints the status code (000 = no response) ----
req() {  # req <token-name|none|garbage> <email>
  local auth=""
  case "$1" in
    none)    auth="" ;;
    garbage) auth="Authorization: Bearer not.a.jwt" ;;
    *)       auth="Authorization: Bearer $(cat "$TOKDIR/$1")" ;;
  esac
  if [ -n "$auth" ]; then
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 -X POST "$API/token" \
      -H "Content-Type: application/json" -H "$auth" -d "{\"user_email\":\"$2\"}"
  else
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 -X POST "$API/token" \
      -H "Content-Type: application/json" -d "{\"user_email\":\"$2\"}"
  fi
}
export -f req

# ---- request mixes: prints "<token> <email>" lines ----
gen_lines() {  # gen_lines <mix> <count>
  local i=0 r
  while [ "$i" -lt "$2" ]; do
    r=$(( RANDOM % 100 ))
    case "$1" in
      valid)     echo "$(pick login admin research) $(pick alice@example.com bob@example.com)" ;;
      unknown)   echo "$(pick login admin research) nobody$RANDOM@example.com" ;;
      attack)    echo "$(pick none garbage expired badscope) $(pick alice@example.com bob@example.com)" ;;
      realistic)
        if   [ "$r" -lt 85 ]; then echo "$(pick login admin research) $(pick alice@example.com bob@example.com)"
        elif [ "$r" -lt 95 ]; then echo "$(pick login admin research) user$RANDOM@example.com"
        else                       echo "$(pick none garbage expired badscope) alice@example.com"; fi ;;
    esac
    i=$(( i + 1 ))
  done
}

# ---- send <rps> requests per second for <seconds>, appending status codes ----
traffic() {  # traffic <seconds> <requests_per_second> <mix>
  local end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    gen_lines "$3" "$2" | xargs -P "$2" -n 2 bash -c 'req "$0" "$1"' >> "$RESULTS" || true
    sleep 1
  done
}

summary() {
  echo "Results:"
  if [ -s "$RESULTS" ]; then
    sort "$RESULTS" | uniq -c | awk '{printf "  %-22s x %s\n", $2, $1}'
  else
    echo "  (none)"
  fi
}

annotate() {  # annotate <name> <start_ms> <text>
  local pw
  pw=$(cat secrets/grafana_admin_password.txt 2>/dev/null) || return 0
  curl -s -o /dev/null --max-time 5 -u "admin:$pw" -H "Content-Type: application/json" \
    -X POST "$GRAFANA/api/annotations" \
    -d "{\"time\":$2,\"timeEnd\":$(now_ms),\"tags\":[\"scenario\",\"$1\"],\"text\":\"Scenario $1: $3\"}" \
    || true
}

run() {  # run <name> <description> <command...>
  local name=$1 desc=$2 start
  shift 2
  : > "$RESULTS"
  say "START $name - $desc"
  start=$(now_ms)
  "$@"
  annotate "$name" "$start" "$desc"
  say "END $name"
  summary
}

# ---- scenarios ----
outage() {  # outage <service> <seconds_down>
  traffic $(( $2 + 50 )) 4 valid &
  local bg=$!
  sleep 20
  say "Stopping $1 for $2 s"
  STOPPED=$1
  docker compose stop "$1" >/dev/null
  sleep "$2"
  say "Starting $1 again"
  docker compose start "$1" >/dev/null
  STOPPED=""
  wait "$bg" || true
}

ttl_abuse() {
  local net ttl i
  net=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
        "$(docker compose ps -q golang-service)" | awk '{print $1}')
  for i in 1 2 3 4 5; do
    for ttl in 99999 -1 30 0; do
      if docker run --rm --network "$net" -v "$PWD/protos:/protos:ro" fullstorydev/grpcurl:v1.9.1 \
           -plaintext -max-time 5 -import-path /protos -proto token.proto \
           -d "{\"user_email\":\"ttl-test@example.com\",\"ttl_seconds\":$ttl}" \
           golang-service:50051 token.TokenService/MintToken >/dev/null 2>&1; then
        echo "accepted_ttl=$ttl" >> "$RESULTS"
      else
        echo "rejected_ttl=$ttl" >> "$RESULTS"
      fi
    done
  done
}

do_baseline() { run baseline      "realistic mixed traffic"                 traffic "${1:-120}" 5  realistic; }
do_unknown()  { run unknown-users "requests for users that do not exist"     traffic "${1:-60}"  3  unknown; }
do_attack()   { run auth-attack   "missing, garbage, expired, wrong-scope JWTs" traffic "${1:-60}" 8 attack; }
do_spike()    { run spike         "burst of high-concurrency valid traffic"  traffic "${1:-30}"  25 valid; }
do_ttl()      { run ttl-abuse     "direct gRPC calls with invalid lifetimes" ttl_abuse; }
do_redis()    { run redis-outage  "Redis stopped"                            outage redis          "${1:-45}"; }
do_token()    { run token-outage  "Go token service stopped"                 outage golang-service "${1:-45}"; }
do_db()       { run db-outage     "Postgres stopped"                         outage postgres       "${1:-45}"; }

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  baseline)      need_api; prepare_tokens; do_baseline "$2" ;;
  unknown-users) need_api; prepare_tokens; do_unknown  "$2" ;;
  auth-attack)   need_api; prepare_tokens; do_attack   "$2" ;;
  spike)         need_api; prepare_tokens; do_spike    "$2" ;;
  ttl-abuse)     need_api; do_ttl ;;
  redis-outage)  need_api; prepare_tokens; do_redis    "$2" ;;
  token-outage)  need_api; prepare_tokens; do_token    "$2" ;;
  db-outage)     need_api; prepare_tokens; do_db       "$2" ;;
  all)
    need_api; prepare_tokens
    do_baseline 90;  sleep 20
    do_unknown 45;   sleep 20
    do_attack 60;    sleep 20
    do_spike 30;     sleep 20
    do_ttl;          sleep 20
    do_redis 45;     sleep 20
    do_token 45;     sleep 20
    do_db 45;        sleep 20
    do_baseline 60
    say "All scenarios done. Open Grafana -> Dashboards -> Token Service (time range: Last 30 minutes)." ;;
  *) usage; exit 1 ;;
esac
