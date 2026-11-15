"""Tests for JWT caller authentication (auth.py).

Run from python-service/:  uv run pytest -q tests/test_auth.py
"""
import base64
import hashlib
import hmac
import json
import time

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

import auth

ISS = "https://idp.internal/realms/platform"
AUD = "token-service"


def _keypair():
    key = ec.generate_private_key(ec.SECP256R1())
    pub = key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return key, pub


@pytest.fixture()
def keys(tmp_path):
    key, pub = _keypair()
    pub_file = tmp_path / "jwt.pub"
    pub_file.write_bytes(pub)
    return key, pub, str(pub_file)


@pytest.fixture()
def verifier(keys):
    _, _, pub_file = keys
    settings = auth.JWTSettings(
        issuer=ISS, audience=AUD, algorithms=("ES256",), required_scope="token:mint",
        leeway_seconds=0, jwks_url=None, public_key_file=pub_file, ca_file=None,
    )
    return auth.JWTVerifier(settings)


def _claims(**overrides):
    now = int(time.time())
    c = {"iss": ISS, "aud": AUD, "sub": "svc-account-1", "azp": "login-service",
         "scope": "token:mint profile", "iat": now, "exp": now + 300}
    c.update(overrides)
    return {k: v for k, v in c.items() if v is not None}


def _sign(key, **overrides):
    return jwt.encode(_claims(**overrides), key, algorithm="ES256")


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


# --- accepted -----------------------------------------------------------------

def test_valid_token_returns_caller(keys, verifier):
    caller = verifier.verify(_sign(keys[0]))
    assert caller.client_id == "login-service"
    assert caller.subject == "svc-account-1"
    assert "token:mint" in caller.scopes


def test_client_id_claim_used_when_no_azp(keys, verifier):
    caller = verifier.verify(_sign(keys[0], azp=None, client_id="admin-console"))
    assert caller.client_id == "admin-console"


# --- rejected -----------------------------------------------------------------

@pytest.mark.parametrize(
    "overrides, error",
    [
        ({"exp": int(time.time()) - 10}, jwt.ExpiredSignatureError),
        ({"aud": "some-other-api"}, jwt.InvalidAudienceError),
        ({"iss": "https://evil.example"}, jwt.InvalidIssuerError),
        ({"exp": None}, jwt.MissingRequiredClaimError),
        ({"iat": None}, jwt.MissingRequiredClaimError),
        ({"azp": "bad id with spaces"}, jwt.InvalidTokenError),
    ],
)
def test_bad_claims_rejected(keys, verifier, overrides, error):
    with pytest.raises(error):
        verifier.verify(_sign(keys[0], **overrides))


def test_missing_scope_rejected(keys, verifier):
    with pytest.raises(auth.InsufficientScopeError):
        verifier.verify(_sign(keys[0], scope="profile email"))


def test_token_signed_by_other_key_rejected(verifier):
    other_key, _ = _keypair()
    with pytest.raises(jwt.InvalidSignatureError):
        verifier.verify(_sign(other_key))


def test_alg_none_rejected(verifier):
    token = jwt.encode(_claims(), None, algorithm="none")
    with pytest.raises(jwt.InvalidTokenError):
        verifier.verify(token)


def test_hs256_algorithm_confusion_rejected(keys, verifier):
    # Attacker signs with HMAC using the PUBLIC key as the shared secret.
    _, pub, _ = keys
    header = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = _b64(json.dumps(_claims()).encode())
    sig = hmac.new(pub, f"{header}.{payload}".encode(), hashlib.sha256).digest()
    with pytest.raises(jwt.InvalidTokenError):
        verifier.verify(f"{header}.{payload}.{_b64(sig)}")


def test_oversized_token_rejected(verifier):
    with pytest.raises(jwt.InvalidTokenError):
        verifier.verify("a" * 9000)


# --- configuration fails closed -----------------------------------------------

@pytest.mark.parametrize(
    "env, message",
    [
        ({"JWT_AUDIENCE": AUD, "JWT_PUBLIC_KEY_FILE": "/k"}, "JWT_ISSUER"),
        ({"JWT_ISSUER": ISS, "JWT_PUBLIC_KEY_FILE": "/k"}, "JWT_AUDIENCE"),
        ({"JWT_ISSUER": ISS, "JWT_AUDIENCE": AUD}, "exactly one"),
        ({"JWT_ISSUER": ISS, "JWT_AUDIENCE": AUD, "JWT_JWKS_URL": "http://idp/jwks"}, "https"),
        ({"JWT_ISSUER": ISS, "JWT_AUDIENCE": AUD, "JWT_PUBLIC_KEY_FILE": "/k",
          "JWT_ALGORITHMS": "HS256"}, "JWT_ALGORITHMS"),
    ],
)
def test_invalid_config_refuses_to_start(monkeypatch, env, message):
    for name in ("JWT_ISSUER", "JWT_AUDIENCE", "JWT_JWKS_URL",
                 "JWT_PUBLIC_KEY_FILE", "JWT_ALGORITHMS"):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    with pytest.raises(RuntimeError, match=message):
        auth.JWTSettings.from_env()


def test_clock_skew_leeway(keys):
    # Production default: 30 s leeway for clock differences between servers.
    key, _, pub_file = keys
    settings = auth.JWTSettings(
        issuer=ISS, audience=AUD, algorithms=("ES256",), required_scope="token:mint",
        leeway_seconds=30, jwks_url=None, public_key_file=pub_file, ca_file=None,
    )
    v = auth.JWTVerifier(settings)
    now = int(time.time())
    # expired 10 s ago: inside the leeway, still accepted
    assert v.verify(_sign(key, exp=now - 10)).client_id == "login-service"
    # expired 120 s ago: beyond the leeway, refused
    with pytest.raises(jwt.ExpiredSignatureError):
        v.verify(_sign(key, exp=now - 120))


def test_jwks_mode_builds_with_installed_pyjwt(tmp_path):
    # Production uses JWT_JWKS_URL. Building the verifier must work with the
    # installed PyJWT version (no network call happens at construction).
    settings = auth.JWTSettings(
        issuer=ISS, audience=AUD, algorithms=("RS256",), required_scope="token:mint",
        leeway_seconds=30, jwks_url="https://idp.internal/jwks", public_key_file=None,
        ca_file=None,
    )
    assert auth.JWTVerifier(settings) is not None


# --- HTTP behaviour through FastAPI -------------------------------------------

def test_http_status_codes(keys, verifier):
    pytest.importorskip("httpx")
    from fastapi import Depends, FastAPI
    from fastapi.testclient import TestClient

    auth._verifier = verifier
    app = FastAPI()

    @app.post("/token")
    def endpoint(caller: auth.Caller = Depends(auth.require_caller)):
        return {"client_id": caller.client_id}

    client = TestClient(app)

    r = client.post("/token")
    assert r.status_code == 401 and r.headers["www-authenticate"].startswith("Bearer")

    r = client.post("/token", headers={"Authorization": "Bearer not.a.jwt"})
    assert r.status_code == 401 and 'error="invalid_token"' in r.headers["www-authenticate"]

    r = client.post("/token", headers={"Authorization": f"Bearer {_sign(keys[0], scope='x')}"})
    assert r.status_code == 403

    r = client.post("/token", headers={"Authorization": f"Bearer {_sign(keys[0])}"})
    assert r.status_code == 200 and r.json() == {"client_id": "login-service"}
