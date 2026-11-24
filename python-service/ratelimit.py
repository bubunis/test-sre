"""A small token-bucket rate limiter, one bucket per calling service.

Each client may make `per_minute` requests a minute on average, with short
bursts of up to `burst`. Buckets live in this process only, so with N API pods
a client can reach N times the limit; a shared limiter (Redis, or the ingress
or API gateway) is the production version.
"""
import math
import threading
import time

from prometheus_client import Counter

RATE_LIMITED = Counter(
    "token_requests_rate_limited_total",
    "Token requests refused because the caller went over its rate limit.",
    ["client_id"],
)


class RateLimiter:
    def __init__(self, per_minute: int, burst: int, clock=time.monotonic):
        self.rate = per_minute / 60.0          # tokens added per second
        self.burst = max(1, burst)
        self.clock = clock
        self._buckets: dict[str, tuple[float, float]] = {}   # client -> (tokens, last time)
        self._lock = threading.Lock()

    def check(self, client_id: str) -> int:
        """0 if the request may go ahead, else the seconds to wait (for Retry-After)."""
        if self.rate <= 0:
            return 0
        now = self.clock()
        with self._lock:
            tokens, last = self._buckets.get(client_id, (float(self.burst), now))
            tokens = min(self.burst, tokens + (now - last) * self.rate)
            if tokens >= 1:
                self._buckets[client_id] = (tokens - 1, now)
                return 0
            self._buckets[client_id] = (tokens, now)
        RATE_LIMITED.labels(client_id=client_id).inc()
        return max(1, math.ceil((1 - tokens) / self.rate))
