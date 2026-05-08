"""Real-time grid-based terminal game using runtime_poc ECS/events/commands/jobs.

Run:  python -m runtime_poc.grid_game

Controls: w/a/s/d = move, q = quit.
Collect '@' apples to score. Timer counts down in real seconds.
Game ends when timer hits 0 or 'q' pressed.

Requires Unix terminal (tty/termios for raw input).
"""

from __future__ import annotations

import os
import random
import select
import sys
import termios
import threading
import time
import tty
from typing import Any

from runtime_poc.ecs import Entity, World, WorldSnapshot
from runtime_poc.events import Event, EventQueue
from runtime_poc.commands import Command, CommandBuffer
from runtime_poc.jobs import JobSystem, JobResult, ECSJob

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GRID_W = 16
GRID_H = 10
INITIAL_APPLES = 7
GAME_TIME = 30.0  # seconds
TICK_RATE = 10  # frames per second
TICK_DT = 1.0 / TICK_RATE

DIRECTION_MAP: dict[str, tuple[int, int]] = {
    "w": (0, -1),
    "a": (-1, 0),
    "s": (0, 1),
    "d": (1, 0),
}

# ---------------------------------------------------------------------------
# Raw terminal input helpers
# ---------------------------------------------------------------------------


class RawTerminal:
    """Context manager for raw terminal mode with non-blocking reads."""

    def __init__(self) -> None:
        self._fd = sys.stdin.fileno()
        self._old_settings: list[Any] = []

    def __enter__(self) -> "RawTerminal":
        self._old_settings = termios.tcgetattr(self._fd)
        tty.setraw(self._fd)
        return self

    def __exit__(self, *args: Any) -> None:
        termios.tcsetattr(self._fd, termios.TCSADRAIN, self._old_settings)

    def read_key(self) -> str | None:
        """Non-blocking read. Drains all pending chars, returns last one.
        If q or Ctrl-C found anywhere in buffer, returns that immediately."""
        last: str | None = None
        while select.select([sys.stdin], [], [], 0.0)[0]:
            ch = sys.stdin.read(1)
            if ch == "q" or ch == "\x03":
                return ch
            last = ch
        return last


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _random_free_pos(
    snapshot: WorldSnapshot, width: int, height: int
) -> tuple[int, int]:
    """Pick random grid cell not occupied by any entity with Position."""
    occupied: set[tuple[int, int]] = set()
    for e in snapshot.all_entities():
        pos = snapshot.get_component(e, "Position")
        if pos is not None:
            occupied.add((pos["x"], pos["y"]))
    attempts = width * height * 2
    while attempts > 0:
        x = random.randint(0, width - 1)
        y = random.randint(0, height - 1)
        if (x, y) not in occupied:
            return (x, y)
        attempts -= 1
    return (0, 0)


def _clear_screen() -> None:
    """ANSI clear + cursor home."""
    sys.stdout.write("\033[2J\033[H")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# ECS Jobs (run on worker threads, read snapshot only)
# ---------------------------------------------------------------------------


def apple_collision_scan_job(snapshot: WorldSnapshot) -> JobResult:
    """Check if player occupies same cell as any apple. Emit apple_collected."""
    events: list[Event] = []
    players: list[tuple[Entity, dict]] = []
    apples: list[tuple[Entity, dict]] = []

    for e in snapshot.all_entities():
        pos = snapshot.get_component(e, "Position")
        if pos is None:
            continue
        if snapshot.get_component(e, "Player") is not None:
            players.append((e, pos))
        elif snapshot.get_component(e, "Apple") is not None:
            apples.append((e, pos))

    for player, ppos in players:
        for apple, apos in apples:
            if ppos["x"] == apos["x"] and ppos["y"] == apos["y"]:
                events.append(
                    Event(
                        type="apple_collected",
                        payload={"player": player, "apple": apple},
                        source="collision_scan",
                    )
                )

    return JobResult(
        job_name="AppleCollisionScanJob",
        events=events,
        thread_name=threading.current_thread().name,
    )


# ---------------------------------------------------------------------------
# Event handlers
# ---------------------------------------------------------------------------


def handle_move_requested(
    event: Event,
    cmd_buf: CommandBuffer,
    eq: EventQueue,
    snapshot: WorldSnapshot,
) -> None:
    entity: Entity = event.payload["entity"]
    dx: int = event.payload["dx"]
    dy: int = event.payload["dy"]
    pos = snapshot.get_component(entity, "Position")
    if pos is None:
        return
    nx = max(0, min(GRID_W - 1, pos["x"] + dx))
    ny = max(0, min(GRID_H - 1, pos["y"] + dy))
    cmd_buf.enqueue(
        Command(
            type="set_component",
            payload={"entity": entity, "name": "Position", "value": {"x": nx, "y": ny}},
        )
    )


def handle_apple_collected(
    event: Event,
    cmd_buf: CommandBuffer,
    eq: EventQueue,
    snapshot: WorldSnapshot,
) -> None:
    player: Entity = event.payload["player"]
    apple: Entity = event.payload["apple"]
    # Only destroy if apple still alive in snapshot
    if not snapshot.is_alive(apple):
        return
    cmd_buf.enqueue(Command(type="destroy_entity", payload={"entity": apple}))
    score = snapshot.get_component(player, "Score")
    new_val = (score["points"] if score else 0) + 1
    cmd_buf.enqueue(
        Command(
            type="set_component",
            payload={"entity": player, "name": "Score", "value": {"points": new_val}},
        )
    )


# ---------------------------------------------------------------------------
# Rendering (reads snapshot only, writes to stdout)
# ---------------------------------------------------------------------------


def render_grid(snapshot: WorldSnapshot, timer_left: float, frame_num: int) -> None:
    """Render bordered grid from snapshot using ANSI cursor positioning."""
    cells: dict[tuple[int, int], str] = {}
    player_score = 0
    for e in snapshot.all_entities():
        pos = snapshot.get_component(e, "Position")
        if pos is None:
            continue
        if snapshot.get_component(e, "Player") is not None:
            cells[(pos["x"], pos["y"])] = "P"
            sc = snapshot.get_component(e, "Score")
            if sc:
                player_score = sc["points"]
        elif snapshot.get_component(e, "Apple") is not None:
            cells[(pos["x"], pos["y"])] = "@"

    lines: list[str] = []
    border_h = "+" + "-" * GRID_W + "+"
    lines.append(border_h)
    for y in range(GRID_H):
        row = "|"
        for x in range(GRID_W):
            row += cells.get((x, y), ".")
        row += "|"
        lines.append(row)
    lines.append(border_h)
    lines.append(f"Score: {player_score}  Timer: {timer_left:.1f}s  Frame: {frame_num}")
    lines.append("Controls: w/a/s/d = move, q = quit")

    # Move cursor home and overwrite (\r\n needed in raw tty mode)
    sys.stdout.write("\033[H")
    for line in lines:
        sys.stdout.write(line + "\033[K\r\n")
    # Clear any leftover lines below
    sys.stdout.write("\033[J")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# Real-time game orchestrator
# ---------------------------------------------------------------------------


class GridGameOrchestrator:
    """Real-time frame loop using runtime_poc machinery."""

    def __init__(self, world: World, player: Entity, game_time: float) -> None:
        self.world = world
        self.player = player
        self.game_time = game_time
        self.time_left = game_time
        self.game_over = False
        self.quit_requested = False
        self.job_system = JobSystem(max_workers=2)
        self.jobs: list[ECSJob] = [apple_collision_scan_job]
        self.frame_number = 0
        self._pending_input: str | None = None

    def set_input(self, key: str | None) -> None:
        """Set input for current frame (called from main loop)."""
        self._pending_input = key

    def run_frame(self, dt: float) -> None:
        self.frame_number += 1
        self.time_left -= dt
        if self.time_left <= 0:
            self.time_left = 0
            self.game_over = True

        eq = EventQueue()
        cmd_buf = CommandBuffer()

        # 1. snapshot
        snap = self.world.snapshot()

        # 2. render
        render_grid(snap, self.time_left, self.frame_number)

        # 3. schedule parallel ECS jobs on snapshot
        job_results = self.job_system.submit_frame_jobs(self.jobs, snap)

        # 4. merge worker events
        for result in job_results:
            eq.push_many(result.events)

        # 5. translate input → events
        key = self._pending_input
        self._pending_input = None
        if key in DIRECTION_MAP:
            dx, dy = DIRECTION_MAP[key]
            eq.push(
                Event(
                    type="move_requested",
                    payload={"entity": self.player, "dx": dx, "dy": dy},
                    source="input",
                )
            )

        # 6. process events (FIFO, safety-limited)
        processed = 0
        safety = 50
        while len(eq) > 0 and processed < safety:
            batch = eq.drain()
            for ev in batch:
                processed += 1
                self._dispatch(ev, cmd_buf, eq, snap)

        # 7. apply commands
        cmd_buf.apply(self.world)

        # 8. respawn apples if none left
        self._maybe_respawn_apples()

    def _dispatch(
        self,
        event: Event,
        cmd_buf: CommandBuffer,
        eq: EventQueue,
        snapshot: WorldSnapshot,
    ) -> None:
        t = event.type
        if t == "move_requested":
            handle_move_requested(event, cmd_buf, eq, snapshot)
        elif t == "apple_collected":
            handle_apple_collected(event, cmd_buf, eq, snapshot)

    def _maybe_respawn_apples(self) -> None:
        apple_count = 0
        for e in self.world.all_entities():
            if self.world.get_component(e, "Apple") is not None:
                apple_count += 1
        if apple_count == 0:
            snap = self.world.snapshot()
            occupied: set[tuple[int, int]] = set()
            for e in snap.all_entities():
                pos = snap.get_component(e, "Position")
                if pos is not None:
                    occupied.add((pos["x"], pos["y"]))
            for _ in range(INITIAL_APPLES):
                ax, ay = _random_free_pos(snap, GRID_W, GRID_H)
                ae = self.world.create_entity()
                self.world.add_component(ae, "Position", {"x": ax, "y": ay})
                self.world.add_component(ae, "Apple", True)
                snap = self.world.snapshot()

    def final_score(self) -> int:
        sc = self.world.get_component(self.player, "Score")
        return sc["points"] if sc else 0

    def shutdown(self) -> None:
        self.job_system.shutdown()


# ---------------------------------------------------------------------------
# Setup & main
# ---------------------------------------------------------------------------


def build_grid_game(seed: int | None = None) -> GridGameOrchestrator:
    if seed is not None:
        random.seed(seed)

    world = World()

    # player
    player = world.create_entity()
    world.add_component(player, "Position", {"x": GRID_W // 2, "y": GRID_H // 2})
    world.add_component(player, "Player", True)
    world.add_component(player, "Score", {"points": 0})

    # apples
    snap = world.snapshot()
    for _ in range(INITIAL_APPLES):
        ax, ay = _random_free_pos(snap, GRID_W, GRID_H)
        ae = world.create_entity()
        world.add_component(ae, "Position", {"x": ax, "y": ay})
        world.add_component(ae, "Apple", True)
        snap = world.snapshot()

    return GridGameOrchestrator(world, player, game_time=GAME_TIME)


def main() -> None:
    if not os.isatty(sys.stdin.fileno()):
        print(
            "Error: real-time mode requires interactive terminal (tty).",
            file=sys.stderr,
        )
        sys.exit(1)

    game = build_grid_game(seed=42)
    raw = RawTerminal()

    _clear_screen()

    try:
        with raw:
            last_time = time.monotonic()
            while not game.game_over and not game.quit_requested:
                # non-blocking input
                key = raw.read_key()
                if key == "q" or key == "\x03":  # q or Ctrl-C
                    game.quit_requested = True
                    break
                game.set_input(key)

                # fixed timestep
                now = time.monotonic()
                dt = now - last_time
                if dt < TICK_DT:
                    time.sleep(TICK_DT - dt)
                    now = time.monotonic()
                    dt = now - last_time
                last_time = now

                game.run_frame(dt)
    finally:
        game.shutdown()

    # final render outside raw mode
    _clear_screen()
    snap = game.world.snapshot()
    render_grid(snap, 0.0, game.frame_number)
    print(f"\nGame Over!  Final score: {game.final_score()}")


if __name__ == "__main__":
    main()
