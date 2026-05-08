"""Demo scenario and frame orchestrator."""

from __future__ import annotations

from runtime_poc.ecs import Entity, World, WorldSnapshot
from runtime_poc.events import Event, EventQueue
from runtime_poc.commands import Command, CommandBuffer
from runtime_poc.jobs import (
    JobSystem,
    movement_scan_job,
    enemy_ai_scan_job,
    death_scan_job,
)
from runtime_poc.scripts import ScriptSystem, ScriptAPI
from runtime_poc.background import BackgroundService

# ---- event handlers ----


def handle_move_requested(
    event: Event, cmd_buf: CommandBuffer, eq: EventQueue, snapshot: WorldSnapshot
) -> None:
    """Move handler that uses snapshot to compute new position."""
    entity = event.payload["entity"]
    dx = event.payload["dx"]
    dy = event.payload["dy"]
    pos = snapshot.get_component(entity, "Position")
    if pos is None:
        return
    new_pos = {"x": pos["x"] + dx, "y": pos["y"] + dy}
    cmd_buf.enqueue(
        Command(
            type="set_component",
            payload={"entity": entity, "name": "Position", "value": new_pos},
        )
    )


def handle_enemy_near_player(
    event: Event, cmd_buf: CommandBuffer, eq: EventQueue
) -> None:
    player = event.payload["player"]
    cmd_buf.enqueue(
        Command(
            type="damage_entity",
            payload={"entity": player, "amount": 1},
        )
    )
    eq.push(
        Event(type="play_sound", payload={"sound": "enemy_attack"}, source="handler")
    )


def handle_damage_requested(
    event: Event, cmd_buf: CommandBuffer, eq: EventQueue
) -> None:
    target = event.payload["target"]
    amount = event.payload.get("amount", 1)
    cmd_buf.enqueue(
        Command(
            type="damage_entity",
            payload={"entity": target, "amount": amount},
        )
    )


def handle_asset_loaded(
    event: Event, cmd_buf: CommandBuffer, eq: EventQueue, script_system: ScriptSystem
) -> None:
    asset_name = event.payload["asset"]
    script_system.notify_asset_loaded(asset_name)


def handle_entity_died(event: Event, cmd_buf: CommandBuffer, eq: EventQueue) -> None:
    entity = event.payload["entity"]
    cmd_buf.enqueue(
        Command(
            type="destroy_entity",
            payload={"entity": entity},
        )
    )


def handle_play_sound(event: Event, cmd_buf: CommandBuffer, eq: EventQueue) -> None:
    print(f"    [sound] play '{event.payload.get('sound', '?')}'")


# ---- enemy script ----


def enemy_script(api: ScriptAPI, enemy: Entity):
    """Cooperative generator script for enemy entity.

    api is a shared ScriptAPI object whose snapshot is refreshed each resume.
    Yield wait conditions; on resume, api already has fresh snapshot.
    """
    yield api.await_asset("enemy_attack_animation")

    while True:
        pos = api.query_component(enemy, "Position")
        players = api.find_by_tag("player")

        if players:
            api.emit(
                "damage_requested",
                {
                    "target": players[0],
                    "amount": 1,
                    "source": enemy,
                },
            )

        yield api.await_frames(2)


# ---- frame orchestrator ----


class FrameOrchestrator:
    """Runs one frame with exact phase order from spec."""

    def __init__(
        self,
        world: World,
        job_system: JobSystem,
        script_system: ScriptSystem,
        background: BackgroundService,
        jobs: list,
    ) -> None:
        self.world = world
        self.job_system = job_system
        self.script_system = script_system
        self.background = background
        self.jobs = jobs
        self.frame_number = 0

    def run_frame(self, dt: float) -> None:
        self.frame_number += 1
        event_queue = EventQueue()
        cmd_buf = CommandBuffer()

        print(f"\n{'='*40}")
        print(f"FRAME {self.frame_number}")

        # 1. drain background completion events
        bg_events = self.background.drain_completion_events()
        event_queue.push_many(bg_events)
        bg_count = len(bg_events)

        # 2. create stable world snapshot
        snapshot = self.world.snapshot()

        # 3-4. schedule ECS jobs and wait
        job_results = self.job_system.submit_frame_jobs(self.jobs, snapshot)

        # 5. merge worker events (in registration order)
        worker_event_count = 0
        for result in job_results:
            if result.thread_name and self.frame_number <= 2:
                print(f"  [job] {result.job_name} ran on {result.thread_name}")
            event_queue.push_many(result.events)
            worker_event_count += len(result.events)

        # Collect all events so far for script wake checks
        all_events_for_scripts = event_queue.drain()
        # Re-push them so event processing sees them
        event_queue.push_many(all_events_for_scripts)

        # 6. resume runnable scripts
        scripts_resumed = self.script_system.resume_runnable_scripts(
            snapshot, event_queue, cmd_buf, all_events_for_scripts
        )

        # 7. process event queue in FIFO order (with safety limit)
        events_processed = 0
        safety = 100
        while len(event_queue) > 0 and events_processed < safety:
            batch = event_queue.drain()
            for ev in batch:
                events_processed += 1
                self._dispatch_event(ev, cmd_buf, event_queue, snapshot)

        # 8. apply command buffer to world
        commands_applied = cmd_buf.apply(self.world)

        # 9. debug render
        player_hp = self._get_player_hp()
        print(f"  background events: {bg_count}")
        print(f"  worker events: {worker_event_count}")
        print(f"  scripts resumed: {scripts_resumed}")
        print(f"  events processed: {events_processed}")
        print(f"  commands applied: {commands_applied}")
        print(f"  player hp: {player_hp}")

        # Print entity positions for debug
        for e in self.world.all_entities():
            tag = self.world.get_component(e, "Tag")
            pos = self.world.get_component(e, "Position")
            hp = self.world.get_component(e, "Health")
            name = tag.get("name", "?") if tag else "?"
            print(f"    [{name}] pos={pos} hp={hp}")

    def _dispatch_event(
        self,
        event: Event,
        cmd_buf: CommandBuffer,
        eq: EventQueue,
        snapshot: WorldSnapshot,
    ) -> None:
        t = event.type
        if t == "move_requested":
            handle_move_requested(event, cmd_buf, eq, snapshot)
        elif t == "enemy_near_player":
            handle_enemy_near_player(event, cmd_buf, eq)
        elif t == "damage_requested":
            handle_damage_requested(event, cmd_buf, eq)
        elif t == "asset_loaded":
            handle_asset_loaded(event, cmd_buf, eq, self.script_system)
        elif t == "entity_died":
            handle_entity_died(event, cmd_buf, eq)
        elif t == "play_sound":
            handle_play_sound(event, cmd_buf, eq)
        # else: unknown event, ignore

    def _get_player_hp(self) -> str:
        for e in self.world.all_entities():
            tag = self.world.get_component(e, "Tag")
            if tag and tag.get("name") == "player":
                hp = self.world.get_component(e, "Health")
                if hp:
                    return str(hp.get("hp", "?"))
        return "dead/missing"


# ---- demo setup ----


def build_demo() -> FrameOrchestrator:
    """Create world, entities, scripts, services for demo scenario."""
    world = World()

    # Player entity
    player = world.create_entity()
    world.add_component(player, "Position", {"x": 0.0, "y": 0.0})
    world.add_component(player, "Health", {"hp": 10})
    world.add_component(player, "Tag", {"name": "player"})

    # Enemy entity
    enemy = world.create_entity()
    world.add_component(enemy, "Position", {"x": 3.0, "y": 0.0})
    world.add_component(enemy, "Velocity", {"x": -1.0, "y": 0.0})
    world.add_component(enemy, "Health", {"hp": 3})
    world.add_component(enemy, "Tag", {"name": "enemy"})

    # Systems
    job_system = JobSystem(max_workers=3)
    script_system = ScriptSystem()
    background = BackgroundService()

    # Attach enemy script
    script_system.add_script(enemy_script, owner=enemy)

    # Request asset load at startup
    background.request_asset("enemy_attack_animation")

    # Jobs list (registration order = merge order)
    jobs = [movement_scan_job, enemy_ai_scan_job, death_scan_job]

    orchestrator = FrameOrchestrator(
        world=world,
        job_system=job_system,
        script_system=script_system,
        background=background,
        jobs=jobs,
    )

    return orchestrator
