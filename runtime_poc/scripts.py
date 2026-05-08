"""Cooperative generator script system — main thread only."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Generator, Union

from runtime_poc.ecs import Entity, WorldSnapshot
from runtime_poc.events import Event, EventQueue
from runtime_poc.commands import Command, CommandBuffer

# ---- wait conditions ----


@dataclass(frozen=True)
class WaitFrames:
    frames: int


@dataclass(frozen=True)
class WaitEvent:
    event_type: str
    entity: Union[Entity, None] = None


@dataclass(frozen=True)
class WaitAsset:
    asset_name: str


WaitCondition = Union[WaitFrames, WaitEvent, WaitAsset]


# ---- script API (passed into generator via closure, refreshed each resume) ----


class ScriptAPI:
    """API available to script generators. Collects events/commands, queries snapshot."""

    def __init__(self) -> None:
        self._snapshot: Union[WorldSnapshot, None] = None
        self.events: list[Event] = []
        self.commands: list[Command] = []

    def _set_snapshot(self, snapshot: WorldSnapshot) -> None:
        self._snapshot = snapshot

    def query_component(self, entity: Entity, component: str) -> Any:
        if self._snapshot is None:
            return None
        return self._snapshot.get_component(entity, component)

    def find_by_tag(self, tag: str) -> list[Entity]:
        if self._snapshot is None:
            return []
        result: list[Entity] = []
        for e in self._snapshot.all_entities():
            t = self._snapshot.get_component(e, "Tag")
            if t is not None and t.get("name") == tag:
                result.append(e)
        return result

    def emit(self, event_type: str, payload: dict) -> None:
        self.events.append(Event(type=event_type, payload=payload, source="script"))

    def command(self, command_type: str, payload: dict) -> None:
        self.commands.append(Command(type=command_type, payload=payload))

    # ---- yield helpers (return wait conditions) ----

    def await_frames(self, n: int) -> WaitFrames:
        return WaitFrames(frames=n)

    def await_event(
        self, event_type: str, entity: Union[Entity, None] = None
    ) -> WaitEvent:
        return WaitEvent(event_type=event_type, entity=entity)

    def await_asset(self, asset_name: str) -> WaitAsset:
        return WaitAsset(asset_name=asset_name)


# ---- script instance ----


@dataclass
class ScriptInstance:
    id: int
    owner: Union[Entity, None]
    coroutine: Union[Generator, None]
    api: ScriptAPI
    wait_condition: Union[WaitCondition, None] = None
    alive: bool = True
    started: bool = False


# ---- script system ----


class ScriptSystem:
    """Manages script instances. Resumes runnable scripts on main thread."""

    def __init__(self) -> None:
        self._scripts: list[ScriptInstance] = []
        self._next_id: int = 0
        self._loaded_assets: set[str] = set()

    def add_script(
        self,
        gen_factory: Any,  # callable(api, owner) -> Generator
        owner: Union[Entity, None] = None,
    ) -> ScriptInstance:
        sid = self._next_id
        self._next_id += 1
        api = ScriptAPI()
        coroutine = gen_factory(api, owner)
        inst = ScriptInstance(
            id=sid,
            owner=owner,
            coroutine=coroutine,
            api=api,
        )
        self._scripts.append(inst)
        return inst

    def resume_runnable_scripts(
        self,
        snapshot: WorldSnapshot,
        event_queue: EventQueue,
        command_buffer: CommandBuffer,
        frame_events: list[Event],
    ) -> int:
        """Resume scripts whose wait conditions are met. Returns count resumed."""
        resumed = 0
        for script in self._scripts:
            if not script.alive:
                continue
            if not self._is_runnable(script, frame_events):
                continue

            # Refresh the API snapshot for this resume
            script.api._set_snapshot(snapshot)
            script.api.events.clear()
            script.api.commands.clear()

            try:
                if not script.started:
                    cond = next(script.coroutine)
                    script.started = True
                else:
                    cond = next(script.coroutine)

                script.wait_condition = cond
                resumed += 1
            except StopIteration:
                script.alive = False
                resumed += 1

            # Collect events/commands from api
            for ev in script.api.events:
                event_queue.push(ev)
            for cmd in script.api.commands:
                command_buffer.enqueue(cmd)

        return resumed

    def notify_asset_loaded(self, asset_name: str) -> None:
        self._loaded_assets.add(asset_name)

    def _is_runnable(self, script: ScriptInstance, frame_events: list[Event]) -> bool:
        cond = script.wait_condition

        # Not yet started
        if not script.started:
            return True

        if cond is None:
            return True

        if isinstance(cond, WaitFrames):
            if cond.frames <= 0:
                return True
            # Decrement for next check
            script.wait_condition = WaitFrames(cond.frames - 1)
            return False

        if isinstance(cond, WaitEvent):
            for ev in frame_events:
                if ev.type == cond.event_type:
                    if cond.entity is None or cond.entity == ev.payload.get("entity"):
                        return True
            return False

        if isinstance(cond, WaitAsset):
            return cond.asset_name in self._loaded_assets

        return False
