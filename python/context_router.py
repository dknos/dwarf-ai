"""
context_router.py — Priority dispatch with concurrency ceiling.
interactive > d2d > memory_event
Drops d2d and memory_event when queue is saturated; never delays interactive.
"""
from __future__ import annotations

import logging
import threading
from collections import deque
from typing import Callable, Optional

logger = logging.getLogger(__name__)

PRIORITY = {"interactive": 0, "d2d": 1, "memory_event": 2, "spontaneous": 1, "sleep_event": 2}


class ContextRouter:
    def __init__(self, max_concurrent: int = 3):
        self._max_concurrent = max_concurrent
        self._active = 0
        self._lock = threading.Lock()
        self._queue: deque[tuple[int, dict, Callable]] = deque()

    def submit(self, ctx: dict, handler: Callable) -> bool:
        """
        Submit a context job. Returns True if accepted, False if dropped.
        Interactive requests are always accepted.
        d2d / memory_event are dropped if queue is already at ceiling.
        """
        req_type = ctx.get("type", "interactive")
        priority = PRIORITY.get(req_type, 1)

        with self._lock:
            if self._active >= self._max_concurrent:
                if req_type != "interactive":
                    logger.debug("Dropping %s request (queue saturated)", req_type)
                    return False
                # Interactive: always queue even when saturated
            self._queue.append((priority, ctx, handler))
            self._queue = deque(sorted(self._queue, key=lambda x: x[0]))
            self._try_dispatch()
        return True

    def _try_dispatch(self) -> None:
        """Called under lock — dispatch one job if capacity allows."""
        if self._active < self._max_concurrent and self._queue:
            _, ctx, handler = self._queue.popleft()
            self._active += 1
            t = threading.Thread(target=self._run, args=(ctx, handler), daemon=True)
            t.start()

    def _run(self, ctx: dict, handler: Callable) -> None:
        try:
            handler(ctx)
        except Exception as exc:
            logger.error("Worker error: %s", exc, exc_info=True)
        finally:
            with self._lock:
                self._active -= 1
                self._try_dispatch()
