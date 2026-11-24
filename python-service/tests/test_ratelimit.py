from ratelimit import RateLimiter


class FakeClock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def test_burst_then_refused():
    clock = FakeClock()
    rl = RateLimiter(per_minute=60, burst=3, clock=clock)
    assert [rl.check("svc") for _ in range(3)] == [0, 0, 0]
    assert rl.check("svc") == 1          # out of tokens: retry after ~1 s


def test_refills_over_time():
    clock = FakeClock()
    rl = RateLimiter(per_minute=60, burst=1, clock=clock)
    assert rl.check("svc") == 0
    assert rl.check("svc") > 0
    clock.t += 1.0                       # 60/min = one token a second
    assert rl.check("svc") == 0


def test_clients_have_separate_buckets():
    rl = RateLimiter(per_minute=60, burst=1, clock=FakeClock())
    assert rl.check("login-service") == 0
    assert rl.check("billing-service") == 0
    assert rl.check("login-service") > 0


def test_zero_turns_it_off():
    rl = RateLimiter(per_minute=0, burst=1, clock=FakeClock())
    assert all(rl.check("svc") == 0 for _ in range(1000))
