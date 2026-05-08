"""Job system — parallel ECS jobs on ThreadPoolExecutor."""

from __future__ import annotations

import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable

from runtime_poc.ecs import Entity, WorldSnapshot
from runtime_poc.events import Event


@dataclass
class JobResult:
    """Output of one ECS job."""

    job_name: str
    events: list[Event]
    thread_name: str = ""


# Type alias for a job function
ECSJob = Callable[[WorldSnapshot], JobResult]


class JobSystem:
    """Submits ECS jobs to a thread pool, collects results."""

    def __init__(self, max_workers: int = 4) -> None:
        self._pool = ThreadPoolExecutor(
            max_workers=max_workers, thread_name_prefix="ecs-worker"
        )

    def submit_frame_jobs(
        self, jobs: list[ECSJob], snapshot: WorldSnapshot
    ) -> list[JobResult]:
        """Run all jobs in parallel, return results in registration order."""
        futures = []
        for job_fn in jobs:
            futures.append(self._pool.submit(job_fn, snapshot))

        results: list[JobResult] = []
        for fut in futures:  # preserve registration order
            results.append(fut.result())
        return results

    def shutdown(self) -> None:
        self._pool.shutdown(wait=True)


# ---- concrete demo jobs ----


def movement_scan_job(snapshot: WorldSnapshot) -> JobResult:
    """Reads Position+Velocity, emits move_requested events."""
    events: list[Event] = []
    for e in snapshot.all_entities():
        pos = snapshot.get_component(e, "Position")
        vel = snapshot.get_component(e, "Velocity")
        if pos is not None and vel is not None:
            events.append(
                Event(
                    type="move_requested",
                    payload={"entity": e, "dx": vel["x"], "dy": vel["y"]},
                    source="movement",
                )
            )
    return JobResult(
        job_name="MovementScanJob",
        events=events,
        thread_name=threading.current_thread().name,
    )


def enemy_ai_scan_job(snapshot: WorldSnapshot) -> JobResult:
    """If enemy near player, emits enemy_near_player."""
    events: list[Event] = []
    enemies: list[tuple[Entity, dict]] = []
    players: list[tuple[Entity, dict]] = []

    for e in snapshot.all_entities():
        tag = snapshot.get_component(e, "Tag")
        pos = snapshot.get_component(e, "Position")
        if tag is None or pos is None:
            continue
        if tag.get("name") == "enemy":
            enemies.append((e, pos))
        elif tag.get("name") == "player":
            players.append((e, pos))

    for enemy, epos in enemies:
        for player, ppos in players:
            dist = abs(epos["x"] - ppos["x"]) + abs(epos["y"] - ppos["y"])
            if dist <= 2.0:
                events.append(
                    Event(
                        type="enemy_near_player",
                        payload={"enemy": enemy, "player": player},
                        source="ai",
                    )
                )

    return JobResult(
        job_name="EnemyAIScanJob",
        events=events,
        thread_name=threading.current_thread().name,
    )


def death_scan_job(snapshot: WorldSnapshot) -> JobResult:
    """If hp <= 0, emits entity_died."""
    events: list[Event] = []
    for e in snapshot.all_entities():
        health = snapshot.get_component(e, "Health")
        if health is not None and health.get("hp", 1) <= 0:
            events.append(
                Event(
                    type="entity_died",
                    payload={"entity": e},
                    source="death_scan",
                )
            )
    return JobResult(
        job_name="DeathScanJob",
        events=events,
        thread_name=threading.current_thread().name,
    )
