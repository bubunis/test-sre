"""JWT bearer authentication for callers of POST /token.

Callers are backend services using the OAuth2 client-credentials flow
(for example a Keycloak service account). Every request must carry
`Authorization: Bearer <access token>`, and that token must be:

  * signed with an asymmetric key from the issuer's JWKS (or a pinned PEM
    public key for dev/test) using an allow-listed algorithm,
  * issued by JWT_ISSUER, for audience JWT_AUDIENCE, not expired,
  * carrying the scope in JWT_REQUIRED_SCOPE.

Configuration is read once at start-up and the service refuses to start
if it is incomplete (fail closed). There is deliberately no switch that
turns authentication off.
"""
from __future__ import annotations

import logging
import os
import re
import ssl
from dataclasses import dataclass

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

logger = logging.getLogger(__name__)

# Asymmetric algorithms only. HS* is excluded so a public key can never be
# used as an HMAC secret (algorithm-confusion attack); "none" is never valid.
_ASYMMETRIC_ALGS = frozenset(
    {"RS256", "RS384", "RS512", "PS256", "PS384", "PS512", "ES256", "ES384", "EdDSA"}
)
_CLIENT_ID_RE = re.compile(r"^[A-Za-z0-9._-]{3,63}$")
_MAX_TOKEN_BYTES = 8192


class InsufficientScopeError(Exception):
    """Token is valid but lacks the scope this endpoint requires."""


@dataclass(frozen=True)
class JWTSettings:
    issuer: str
    audience: str
    algorithms: tuple[str, ...]
    required_scope: str
    leeway_seconds: int
    jwks_url: str | None
    public_key_file: str | None
    ca_file: str | None

    @classmethod
    def from_env(cls) -> "JWTSettings":
        issuer = os.getenv("JWT_ISSUER", "").strip()
        audience = os.getenv("JWT_AUDIENCE", "").strip()
        jwks_url = os.getenv("JWT_JWKS_URL", "").strip() or None
        public_key_file = os.getenv("JWT_PUBLIC_KEY_FILE", "").strip() or None
        algorithms = tuple(
            a.strip()
            for a in os.getenv("JWT_ALGORITHMS", "RS256,ES256").split(",")
            if a.strip()
        )

        problems = []
        if not issuer:
            problems.append("JWT_ISSUER is required")
        if not audience:
            problems.append("JWT_AUDIENCE is required")
        if bool(jwks_url) == bool(public_key_file):
            problems.append("set exactly one of JWT_JWKS_URL or JWT_PUBLIC_KEY_FILE")
        if jwks_url and not jwks_url.startswith("https://"):
            problems.append("JWT_JWKS_URL must use https://")
        if not algorithms or set(algorithms) - _ASYMMETRIC_ALGS:
            problems.append(
                f"JWT_ALGORITHMS must be a subset of {sorted(_ASYMMETRIC_ALGS)}"
            )
        if problems:
            raise RuntimeError("Invalid JWT configuration: " + "; ".join(problems))

        return cls(
            issuer=issuer,
            audience=audience,
            algorithms=algorithms,
            required_scope=os.getenv("JWT_REQUIRED_SCOPE", "token:mint").strip(),
            leeway_seconds=int(os.getenv("JWT_LEEWAY_SECONDS", "30")),
            jwks_url=jwks_url,
            public_key_file=public_key_file,
            ca_file=os.getenv("JWT_CA_FILE", "").strip() or None,
        )


@dataclass(frozen=True)
class Caller:
    """The authenticated service that is calling the API."""

    client_id: str
    subject: str
    scopes: frozenset[str]


class JWTVerifier:
    def __init__(self, settings: JWTSettings):
        self.settings = settings
        self._jwks_client: jwt.PyJWKClient | None = None
        self._static_key: bytes | None = None

        if settings.jwks_url:
            # Keys are cached for 5 minutes; an unknown `kid` triggers one refetch,
            # which is how key rotation at the issuer is picked up.
            self._jwks_client = jwt.PyJWKClient(
                settings.jwks_url,
                cache_keys=True,
                lifespan=300,
                timeout=5,
                ssl_context=ssl.create_default_context(cafile=settings.ca_file),
            )
        else:
            with open(settings.public_key_file, "rb") as fh:
                self._static_key = fh.read()

    def _signing_key(self, token: str):
        if self._jwks_client is not None:
            return self._jwks_client.get_signing_key_from_jwt(token).key
        return self._static_key

    def verify(self, token: str) -> Caller:
        if len(token) > _MAX_TOKEN_BYTES:
            raise jwt.InvalidTokenError("token too large")

        s = self.settings
        claims = jwt.decode(
            token,
            self._signing_key(token),
            algorithms=list(s.algorithms),
            audience=s.audience,
            issuer=s.issuer,
            leeway=s.leeway_seconds,
            options={"require": ["exp", "iat", "iss", "aud", "sub"]},
        )

        raw_scope = claims.get("scope", claims.get("scp", ""))
        scopes = frozenset(raw_scope.split() if isinstance(raw_scope, str) else raw_scope)
        if s.required_scope and s.required_scope not in scopes:
            raise InsufficientScopeError(s.required_scope)

        # Client-credentials tokens name the client in `azp` (Keycloak) or
        # `client_id` (RFC 9068); `sub` is the fallback.
        client_id = claims.get("azp") or claims.get("client_id") or claims["sub"]
        if not isinstance(client_id, str) or not _CLIENT_ID_RE.fullmatch(client_id):
            raise jwt.InvalidTokenError("client id claim is missing or malformed")

        return Caller(client_id=client_id, subject=str(claims["sub"]), scopes=scopes)


_verifier: JWTVerifier | None = None
_bearer = HTTPBearer(auto_error=False)


def configure_auth(settings: JWTSettings | None = None) -> None:
    """Build the verifier at start-up. Raises if configuration is invalid."""
    global _verifier
    _verifier = JWTVerifier(settings or JWTSettings.from_env())
    s = _verifier.settings
    logger.info(
        "JWT auth enabled",
        extra={
            "jwt.issuer": s.issuer,
            "jwt.audience": s.audience,
            "jwt.algorithms": ",".join(s.algorithms),
            "jwt.key_source": "jwks" if s.jwks_url else "pem",
        },
    )


def _unauthorized(error: str | None = None) -> HTTPException:
    challenge = 'Bearer realm="token-service"'
    if error:
        challenge += f', error="{error}"'
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="unauthorized",
        headers={"WWW-Authenticate": challenge},
    )


def require_caller(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> Caller:
    """FastAPI dependency: returns the verified caller or raises 401/403/503."""
    if _verifier is None:  # configure_auth() was not called: fail closed
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "auth not configured")
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise _unauthorized()

    try:
        return _verifier.verify(credentials.credentials)
    except InsufficientScopeError:
        logger.info("jwt rejected", extra={"jwt.reason": "insufficient_scope"})
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="forbidden",
            headers={"WWW-Authenticate": 'Bearer error="insufficient_scope"'},
        )
    except jwt.PyJWKClientConnectionError:
        # The issuer's JWKS endpoint is unreachable: our fault, not the caller's.
        logger.error("jwks endpoint unreachable", extra={"jwt.reason": "jwks_unreachable"})
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "service unavailable")
    except (jwt.PyJWKClientError, jwt.InvalidTokenError) as exc:
        # Log the failure class only; never the token or its claims.
        logger.info("jwt rejected", extra={"jwt.reason": type(exc).__name__})
        raise _unauthorized("invalid_token")
