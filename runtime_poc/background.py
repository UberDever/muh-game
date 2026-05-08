"""Background asset/IO service — runs outside main frame."""

from __future__ import annotations

import threading
import time
from concurrent.futures import ThreadPoolExecutor

from runtime_poc.events import Event


class BackgroundService:
    """Simulates async asset loading on background threads."""

    def __init__(self) -> None:
        self._pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="bg-loader")
        self._lock = threading.Lock()
        self._completed: list[Event] = []

    def request_asset(self, asset_name: str) -> None:
        """Submit asset load request to background pool."""
        self._pool.submit(self._load_asset, asset_name)

    def drain_completion_events(self) -> list[Event]:
        """Called on main thread at frame start. Returns and clears completed events."""
        with self._lock:
            result = list(self._completed)
            self._completed.clear()
        return result

    def shutdown(self) -> None:
        self._pool.shutdown(wait=True)

    def _load_asset(self, asset_name: str) -> None:
        """Simulated load — runs on background thread."""
        thread_name = threading.current_thread().name
        print(f"  [background] loading '{asset_name}' on {thread_name}")
        time.sleep(0.05)  # simulate IO
        event = Event(
            type="asset_loaded",
            payload={"asset": asset_name},
            source="background",
        )
        with self._lock:
            self._completed.append(event)
        print(f"  [background] '{asset_name}' loaded on {thread_name}")
