"""DEV/CI ONLY: print an access token signed with the dev private key.

Run it through scripts/dev-token.sh, which mounts the key read-only into a
throwaway python-service container (PyJWT is already installed there).

Arguments: [client_id] [scope] [ttl_seconds]
  client_id    who is calling                 default: login-service
  scope        space-separated scopes         default: token:mint
  ttl_seconds  token lifetime; negative = already expired   default: 300
               (the API allows 30 s of clock skew, so use -120 to test expiry)
"""
import os
import sys
import time

import jwt

client_id = sys.argv[1] if len(sys.argv) > 1 else "login-service"
scope = sys.argv[2] if len(sys.argv) > 2 else "token:mint"
ttl = int(sys.argv[3]) if len(sys.argv) > 3 else 300

with open(os.getenv("DEV_JWT_KEY", "/run/dev/jwt.key")) as f:
    private_key = f.read()

now = int(time.time())
claims = {
    "iss": "https://idp.dev.local",      # must match JWT_ISSUER in docker-compose.yml
    "aud": "token-service",              # must match JWT_AUDIENCE
    "sub": f"service-account-{client_id}",
    "azp": client_id,
    "scope": scope,
    "iat": now,
    "exp": now + ttl,
}
print(jwt.encode(claims, private_key, algorithm="ES256"))
