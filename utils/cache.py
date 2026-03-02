"""
Simple in-memory + optional Redis cache for trained Prophet models.
Avoids re-training the same model on every request.
"""

import os
import time
import pickle
import hashlib
from typing import Any, Optional

# In-process memory cache: key → (value, expires_at)
_memory_cache: dict[str, tuple[Any, float]] = {}

DEFAULT_TTL = 3600  # 1 hour


def _make_key(namespace: str, **kwargs) -> str:
    raw = f"{namespace}:" + ":".join(f"{k}={v}" for k, v in sorted(kwargs.items()))
    return hashlib.md5(raw.encode()).hexdigest()


def cache_get(namespace: str, **kwargs) -> Optional[Any]:
    key = _make_key(namespace, **kwargs)

    # Try Redis first (if available)
    redis_client = _get_redis()
    if redis_client:
        try:
            data = redis_client.get(key)
            if data:
                return pickle.loads(data)
        except Exception:
            pass

    # Fall back to in-process memory
    entry = _memory_cache.get(key)
    if entry and time.time() < entry[1]:
        return entry[0]
    return None


def cache_set(namespace: str, value: Any, ttl: int = DEFAULT_TTL, **kwargs) -> None:
    key = _make_key(namespace, **kwargs)

    # Try Redis first
    redis_client = _get_redis()
    if redis_client:
        try:
            redis_client.setex(key, ttl, pickle.dumps(value))
            return
        except Exception:
            pass

    # Fall back to in-process memory
    _memory_cache[key] = (value, time.time() + ttl)


def cache_invalidate(namespace: str, **kwargs) -> None:
    key = _make_key(namespace, **kwargs)
    _memory_cache.pop(key, None)
    redis_client = _get_redis()
    if redis_client:
        try:
            redis_client.delete(key)
        except Exception:
            pass


_redis_client = None
_redis_checked = False


def _get_redis():
    global _redis_client, _redis_checked
    if _redis_checked:
        return _redis_client
    _redis_checked = True
    redis_url = os.getenv("REDIS_URL", "")
    if not redis_url:
        return None
    try:
        import redis
        _redis_client = redis.from_url(redis_url, socket_connect_timeout=2)
        _redis_client.ping()
    except Exception:
        _redis_client = None
    return _redis_client
