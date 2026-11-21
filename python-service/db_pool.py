"""Postgres connection pool with Prometheus metrics.

Before this, every request opened and closed its own database connection.
Now connections are reused from a pool:

  * at most DB_POOL_MAX connections are open at once
  * DB_POOL_MIN connections stay open between requests; extra ones are closed when returned
  * a request waits up to DB_POOL_TIMEOUT_SECONDS for a free connection, then gets PoolTimeout
  * every query is limited by a server-side statement timeout

Metrics (served on the API's /metrics):
  db_pool_connections_max     the configured maximum
  db_pool_connections_in_use  checked out right now
  db_pool_connections_idle    open and waiting in the pool
  db_pool_wait_seconds        time spent waiting for a free connection
  db_pool_timeouts_total      requests that gave up waiting
  db_query_duration_seconds   query time, by query name
"""
import threading
import time
from contextlib import contextmanager

import psycopg2
from psycopg2 import pool as pg_pool
from prometheus_client import Counter, Gauge, Histogram

POOL_MAX = Gauge("db_pool_connections_max", "Maximum number of connections the pool may open")
POOL_IN_USE = Gauge("db_pool_connections_in_use", "Connections currently checked out of the pool")
POOL_IDLE = Gauge("db_pool_connections_idle", "Open connections waiting in the pool")
POOL_WAIT = Histogram(
    "db_pool_wait_seconds", "Time spent waiting for a free connection",
    buckets=(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5),
)
POOL_TIMEOUTS = Counter("db_pool_timeouts_total", "Requests that gave up waiting for a free connection")
QUERY_DURATION = Histogram(
    "db_query_duration_seconds", "Database query duration", ["query"],
    buckets=(0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5),
)


class PoolTimeout(Exception):
    """No connection became free in time."""


class ConnectionPool:
    def __init__(self, dsn, password, minconn=2, maxconn=10, acquire_timeout=2.0,
                 statement_timeout_ms=2000, connect_timeout=3):
        if not 0 <= minconn <= maxconn or maxconn < 1:
            raise ValueError("need 0 <= DB_POOL_MIN <= DB_POOL_MAX and DB_POOL_MAX >= 1")
        self.minconn, self.maxconn, self.acquire_timeout = minconn, maxconn, acquire_timeout
        self._connect_args = dict(dsn=dsn, password=password, connect_timeout=connect_timeout,
                                  options=f"-c statement_timeout={statement_timeout_ms}")
        # psycopg2's pool fails at once when it's full; this semaphore makes callers wait instead
        self._slots = threading.BoundedSemaphore(maxconn)
        self._pool = None
        self._lock = threading.Lock()
        POOL_MAX.set(maxconn)
        POOL_IDLE.set_function(self._idle_count)

    def _idle_count(self):
        p = self._pool
        return len(p._pool) if p is not None else 0  # psycopg2 keeps idle connections in ._pool

    def _get_pool(self):
        # Created on first use, so the API can start before the database is reachable
        if self._pool is None:
            with self._lock:
                if self._pool is None:
                    self._pool = pg_pool.ThreadedConnectionPool(self.minconn, self.maxconn, **self._connect_args)
        return self._pool

    @contextmanager
    def connection(self):
        started = time.perf_counter()
        if not self._slots.acquire(timeout=self.acquire_timeout):
            POOL_TIMEOUTS.inc()
            raise PoolTimeout(f"no database connection free within {self.acquire_timeout}s")
        POOL_WAIT.observe(time.perf_counter() - started)

        conn, broken = None, False
        try:
            conn = self._get_pool().getconn()
            POOL_IN_USE.inc()
            yield conn
        except (psycopg2.OperationalError, psycopg2.InterfaceError):
            broken = True  # the connection may be dead: don't hand it to the next request
            raise
        finally:
            if conn is not None:
                POOL_IN_USE.dec()
                self._pool.putconn(conn, close=broken or bool(conn.closed))
            self._slots.release()

    def _run(self, name, sql, params, fetch):
        with self.connection() as conn:
            started = time.perf_counter()
            try:
                with conn.cursor() as cur:
                    cur.execute(sql, params)
                    return fetch(cur)
            finally:
                QUERY_DURATION.labels(query=name).observe(time.perf_counter() - started)

    def fetchone(self, name, sql, params=()):
        return self._run(name, sql, params, lambda cur: cur.fetchone())

    def fetchall(self, name, sql, params=()):
        return self._run(name, sql, params, lambda cur: cur.fetchall())

    def ping(self):
        """True if a connection can be checked out and answers SELECT 1."""
        return self.fetchone("ping", "SELECT 1") == (1,)
