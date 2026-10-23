"""
A tiny time-to-live cache.

The provider's own cache (``services/recommend.py``) already covers the radio
and the familiarity snapshot. This one covers the *new* fetches the
recommender makes — the home feed's recommendation row, the local affinity
view and the outside services — so none of them is asked for twice inside its
window.

Deliberately boring: a dict, a lock and a monotonic clock. The value is
produced outside the lock, so a slow call never blocks another thread.
"""

from __future__ import annotations

import threading
import time
from typing import Callable, TypeVar

T = TypeVar("T")

_cache: dict[str, tuple[float, object]] = {}
_lock = threading.Lock()


def clear() -> None:
    """Reset every entry (tests, and "clear listening data")."""
    with _lock:
        _cache.clear()


def cached(key: str, ttl: float, producer: Callable[[], T]) -> T:
    """The cached value for *key*, or a freshly produced one."""
    now = time.monotonic()
    with _lock:
        hit = _cache.get(key)
        if hit and hit[0] > now:
            return hit[1]  # type: ignore[return-value]

    value = producer()  # outside the lock: never hold it across I/O

    with _lock:
        _cache[key] = (time.monotonic() + ttl, value)
    return value
