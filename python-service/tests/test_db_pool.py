"""Tests for the connection pool (db_pool.py), with a fake database connection.

Run from python-service/:  uv run pytest -q tests/test_db_pool.py
"""
import threading
import time

import psycopg2
import pytest
from prometheus_client import REGISTRY

import db_pool


class FakeCursor:
    def __init__(self, conn):
        self.conn = conn

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, params=()):
        if self.conn.fail_with:
            raise self.conn.fail_with
        time.sleep(self.conn.delay)

    def fetchone(self):
        return (1,)

    def fetchall(self):
        return [(1,)]


class FakeInfo:
    transaction_status = psycopg2.extensions.TRANSACTION_STATUS_IDLE


class FakeConn:
    opened = 0

    def __init__(self, *args, **kwargs):
        FakeConn.opened += 1
        self.closed = 0
        self.fail_with = None
        self.delay = 0
        self.info = FakeInfo()

    def cursor(self):
        return FakeCursor(self)

    def rollback(self):
        pass

    def close(self):
        self.closed = 1


@pytest.fixture()
def pool(monkeypatch):
    FakeConn.opened = 0
    monkeypatch.setattr(psycopg2, "connect", FakeConn)
    return db_pool.ConnectionPool("postgres://x@db/tokendb", "pw", minconn=1, maxconn=2, acquire_timeout=0.2)


def metric(name, **labels):
    return REGISTRY.get_sample_value(name, labels) or 0


def test_connections_are_reused(pool):
    for _ in range(5):
        assert pool.fetchone("q", "SELECT 1") == (1,)
    assert FakeConn.opened == 1           # one connection, reused five times
    assert metric("db_pool_connections_in_use") == 0
    assert metric("db_pool_connections_idle") == 1
    assert metric("db_pool_connections_max") == 2


def test_in_use_gauge_while_checked_out(pool):
    with pool.connection():
        assert metric("db_pool_connections_in_use") == 1
    assert metric("db_pool_connections_in_use") == 0


def test_waits_then_times_out_when_full(pool):
    before = metric("db_pool_timeouts_total")
    release = threading.Event()

    def hold():
        with pool.connection():
            release.wait(2)

    holders = [threading.Thread(target=hold) for _ in range(2)]
    for t in holders:
        t.start()
    time.sleep(0.05)
    with pytest.raises(db_pool.PoolTimeout):
        with pool.connection():
            pass
    release.set()
    for t in holders:
        t.join()
    assert metric("db_pool_timeouts_total") == before + 1
    assert pool.ping()                    # usable again once connections are back


def test_broken_connection_is_not_reused(pool):
    with pytest.raises(psycopg2.OperationalError):
        with pool.connection() as conn:
            conn.fail_with = psycopg2.OperationalError("server closed the connection")
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
    assert conn.closed == 1               # thrown away, not returned to the pool
    pool.ping()
    assert FakeConn.opened == 2           # a fresh connection replaced it


def test_pool_is_created_lazily(monkeypatch):
    FakeConn.opened = 0
    monkeypatch.setattr(psycopg2, "connect", FakeConn)
    p = db_pool.ConnectionPool("postgres://x@db/tokendb", "pw", minconn=1, maxconn=2)
    assert FakeConn.opened == 0           # the API can start before the database is up
    p.ping()
    assert FakeConn.opened == 1


def test_statement_timeout_is_set(pool, monkeypatch):
    seen = {}

    def capture(*args, **kwargs):
        seen.update(kwargs)
        return FakeConn()

    monkeypatch.setattr(psycopg2, "connect", capture)
    p = db_pool.ConnectionPool("postgres://x@db/tokendb", "pw", statement_timeout_ms=1500)
    p.ping()
    assert seen["options"] == "-c statement_timeout=1500"
    assert seen["connect_timeout"] == 3


def test_query_duration_is_recorded(pool):
    before = metric("db_query_duration_seconds_count", query="user_permissions")
    pool.fetchone("user_permissions", "SELECT 1")
    assert metric("db_query_duration_seconds_count", query="user_permissions") == before + 1


def test_invalid_sizes_are_refused():
    with pytest.raises(ValueError):
        db_pool.ConnectionPool("dsn", "pw", minconn=5, maxconn=2)
