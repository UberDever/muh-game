"""Typed events and deterministic event queue."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Event:
    """Immutable typed event."""

    type: str
    payload: dict
    source: str
    seq: int = 0


class EventQueue:
    """Deterministic FIFO event queue with monotonic seq assignment."""

    def __init__(self) -> None:
        self._events: list[Event] = []
        self._next_seq: int = 0

    def push(self, event: Event) -> None:
        assigned = Event(
            type=event.type,
            payload=event.payload,
            source=event.source,
            seq=self._next_seq,
        )
        self._next_seq += 1
        self._events.append(assigned)

    def push_many(self, events: list[Event]) -> None:
        for e in events:
            self.push(e)

    def drain(self) -> list[Event]:
        """Remove and return all events in FIFO order."""
        result = list(self._events)
        self._events.clear()
        return result

    def __len__(self) -> int:
        return len(self._events)
