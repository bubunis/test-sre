# Security hardening log

This is my running log of the security work on the token service: what I changed, why, how I tested it, and what's still open. I'm keeping everything Docker-only (no cloud, no Kubernetes) and doing one change at a time, each on its own branch and merged only when CI passes.

I used Claude to help draft some of the code, tests and docs. I reviewed every change, ran the tests myself, and made the calls on what to fix and in which order.

*Last updated: 16 November 2026*

## Where things stand

- **Step 1 – secrets and closed ports:** done, merged
- **Step 2 – token lifetime cap:** done, merged
- **Step 2b – network isolation:** deferred (see below)
- **Step 3 – JWT auth for callers:** done, merged
- **Step 4 – non-root containers, pinned images:** not started
- **Step 5 – least-privilege DB user:** not started

## What I started with

The service has two parts. A Python (FastAPI) API looks up a user's permissions in Postgres and, if the user exists, asks a Go gRPC service to mint a token. The Go service stores the token in Redis with an expiry. Everything ran on one flat Docker network.

When I went through it, these were the problems that mattered most:

- The Postgres password was `postgres`, hardcoded in the compose file and as a default in the Python code. Redis had no password at all.
- Every internal port was published on the host: Postgres, Redis, gRPC, metrics, OTLP, Jaeger and Prometheus.
- The caller decided how long a token lived. A lifetime of 0, which is also what you get if you leave the field out, meant the token **never expired**.
- `POST /token` had no authentication. Anyone who could reach port 8000 could get a token for any existing user.
- Containers ran as root from `:latest` images, and the API connected to Postgres as the superuser.

I tackled them in that order: first what anyone on the network could reach, then tokens that could live forever, then who's allowed to ask for tokens.

## Step 1 – Secrets and closed ports

**Branch:** `step1-secrets-and-ports`

I added `scripts/init-secrets.sh`, which generates random passwords into a `secrets/` folder. That folder is git-ignored, so passwords can't end up in the repo. The containers read them as Docker secrets instead of environment variables. Postgres uses `POSTGRES_PASSWORD_FILE`, Redis gets its password from a mounted config file, and the two services get a *path* to the password rather than the value. I also removed every published port except the API on 8000, and bound the Jaeger and Prometheus UIs to `127.0.0.1` so they're only reachable from my machine.

A few choices worth explaining:

- **Files instead of environment variables.** Environment variables leak easily: they show up in `docker inspect`, process listings and crash dumps.
- **The Redis password goes in a config file**, not `--requirepass`, because command-line arguments are visible in `ps`.
- **The secret files are `644` and the folder is `700`.** Outside Swarm, Compose mounts secret files with their host permissions, and Postgres and Redis run as their own users inside the container, so they need to be able to read them. The `700` folder still keeps other host users out.
- **Passwords are hex** (`openssl rand -hex 32`), because base64 characters like `/` and `+` break connection URLs.
- I had to run **`docker compose down -v` once**, because Postgres only sets its password the first time it initialises, and the old volume still had `postgres`.

**How I tested it.** Only 8000 shows as public in `docker compose ps`, with the two UIs on `127.0.0.1`. `nc` to Postgres and Redis from the host is refused. `redis-cli PING` without the password gets `NOAUTH`. The normal token flow for alice still works. `git status` never shows `secrets/`.

**Gotcha:** CI calls the secrets script, so git has to store it as executable. It's worth checking `git ls-files -s scripts/init-secrets.sh` shows `100755` before pushing. I later switched CI to `bash scripts/init-secrets.sh` so it doesn't depend on that at all.

## Step 2 – Capping token lifetime

**Branch:** `step2-token-ttl`

The Go service passed the caller's `ttl_seconds` straight into Redis `SET`, and in Redis an expiry of 0 means "keep forever". I moved the decision to the server, in a small package of its own (`golang-service/internal/tokenpolicy`):

- 0 or not set → 15 minutes
- 60 to 3600 seconds → used as requested
- anything else → refused with `InvalidArgument`

I chose to **refuse** bad values rather than quietly cap them. A caller asking for a week-long token is either buggy or malicious, and an explicit error shows up in the logs and in `tokens_minted_total{status="rejected"}`. While I was in there, I also fixed the unchecked `crypto/rand.Read`: if the random source ever failed, the old code would have handed out a predictable token. The Python API asks for 3600, so nothing changed for normal use.

**How I tested it.** Seven unit tests cover 0, the minimum, the maximum, just below, just above, negative and a huge value. Against the running stack, calling the Go service directly with `grpcurl`: 0 gives a token, 99999 and -1 are refused, and `redis-cli TTL` on a new token shows 900 or less (before the fix it was -1). CI runs `go test` now too.

**Gotcha:** the first CI run for this branch failed with `init-secrets.sh: No such file or directory`. I'd created the Step 2 branch before Step 1 was merged, so the new CI file called a script that wasn't on the branch yet. I fixed it by merging Step 1 first and rebasing Step 2 on top. Lesson: always start a new step from an up-to-date `main`.

## Something I found along the way – the Go service trusts anyone

While testing Step 2, I minted a token for `test@example.com`, a user that doesn't exist. That's because the Go service doesn't check users at all: the API does that before calling it. My test skipped the API and called the Go service directly from inside the Docker network. Through the API, the same request correctly gets a 404.

So any container on that network (Jaeger, Prometheus, the collector) could mint tokens for anyone if it were compromised. I prepared a fix, **Step 2b**: separate Docker networks, plus making the Go service accept gRPC only on the network it shares with the API. Port isolation alone isn't enough, because Prometheus has to share a network with the Go service to scrape it. I've **deferred** 2b for now to get caller authentication in first. The risk needs an attacker who already controls a container, but it's still open. Longer term, mTLS between the API and the Go service is the proper fix.

## Step 3 – Callers have to authenticate

**Branch:** `step3-jwt-auth`

Every `POST /token` now needs `Authorization: Bearer <JWT>`. The check lives in `python-service/auth.py`. It verifies the signature (asymmetric algorithms only), the issuer and audience, that `exp`, `iat` and `sub` are present and the token hasn't expired (with 30 s of clock-skew leeway), and that the token has the `token:mint` scope. A missing or bad token gets 401, a missing scope gets 403, and if the identity provider's key endpoint is unreachable the API returns 503. If the JWT settings are missing, the API refuses to start. I deliberately didn't add a switch to turn auth off.

For dev and CI, there's no real identity provider, so `init-secrets.sh` also creates a local key pair. The API only gets the public key. `scripts/dev-token.sh` signs test tokens with the private key in a throwaway container, so the key never ends up in an image. In production, `JWT_JWKS_URL` points at the real identity provider instead.

Why these choices:

- **JWT rather than mTLS client certificates** (decision D1). It works with a standard identity provider through the OAuth2 client-credentials flow, and doesn't need certificate infrastructure yet.
- **Asymmetric algorithms only**, which rules out two classic attacks: `alg=none` (no signature at all), and HS256 key confusion, where an attacker signs with HMAC using the *public* key as the secret.
- **Failing closed**, so a missing setting can't accidentally leave the endpoint open.

**How I tested it.** There are 20 unit tests: expired, wrong audience, wrong issuer, missing claims, wrong signing key, `alg=none`, HS256 confusion, oversized token, missing scope, the leeway boundary, and bad config. In CI, a request with no token gets 401, a garbage token 401, the wrong scope 403, an expired token 401, and a valid token gets alice's token. Locally, the API refuses to start with `JWT_ISSUER` empty.

**Gotcha:** the expired-token check in CI first came back 200. My test token had expired only 10 seconds earlier, which is inside the 30-second leeway, so the API was right to accept it. The test was wrong. The unit tests hadn't caught it because they used a leeway of 0. I changed the test token to expire 2 minutes earlier, and added a unit test that pins both sides of the boundary. Lesson: test boundaries with the real setting, not a test-only value.

What JWT doesn't solve yet: it proves *who* is calling, not *which users* that caller is allowed to request tokens for. That's decision D2, per-client grants, and it's still open.

## Still open

- **Any authenticated caller can request any user.** Needs per-client grants (D2).
- **Any container on the Docker network can call the Go service directly.** Step 2b, or mTLS.
- **Traffic between containers isn't encrypted.** Planned with mTLS.
- **Tokens are stored in Redis as the raw key.** Anyone who can read Redis can copy a valid token. I want to store a SHA-256 of the token instead.
- **Containers still run as root, and the API still uses the Postgres superuser.** These are Steps 4 and 5.
- **`/metrics` is on the public port, and there are no real healthchecks.** CI still waits with `sleep 15`.
- **Secret rotation is manual.**

## Next

1. **Step 4:** non-root containers, images pinned by digest, a `.dockerignore` (the Python image currently copies in `.venv`).
2. **Step 5:** a `token_api` Postgres role with `SELECT` on the four permission tables only.
3. **After that:** per-client grants, hashed token storage, then network isolation and mTLS.

## Commands I keep reaching for

```bash
# fresh start
bash scripts/init-secrets.sh
docker compose up -d --build

# get a dev JWT and request a token
JWT=$(bash scripts/dev-token.sh)
curl -s -X POST http://localhost:8000/token \
  -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"user_email": "alice@example.com"}'

# how long a token has left (-1 would mean it never expires)
docker compose exec -T -e REDISCLI_AUTH="$(cat secrets/redis_password.txt)" \
  redis redis-cli TTL "token:<token>"

# start each step from an up-to-date main
git checkout main && git pull && git checkout -b <step-branch>
```
