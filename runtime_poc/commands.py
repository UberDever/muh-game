"""Command buffer — deferred world mutation."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from runtime_poc.ecs import Entity, World


@dataclass(frozen=True)
class Command:
    """Immutable command descriptor."""

    type: str
    payload: dict


class CommandBuffer:
    """Collects commands, applies them to World in one batch."""

    def __init__(self) -> None:
        self._commands: list[Command] = []

    def enqueue(self, cmd: Command) -> None:
        self._commands.append(cmd)

    def apply(self, world: World) -> int:
        """Apply all queued commands to *world*. Returns count applied."""
        count = 0
        for cmd in self._commands:
            _apply_one(cmd, world)
            count += 1
        self._commands.clear()
        return count

    def __len__(self) -> int:
        return len(self._commands)


# ---- command executors ----


def _apply_one(cmd: Command, world: World) -> None:
    t = cmd.type
    p = cmd.payload

    if t == "spawn_entity":
        e = world.create_entity()
        for comp_name, comp_val in p.get("components", {}).items():
            world.add_component(e, comp_name, comp_val)

    elif t == "destroy_entity":
        entity: Entity = p["entity"]
        if world.is_alive(entity):
            world.destroy_entity(entity)

    elif t == "set_component":
        entity = p["entity"]
        if world.is_alive(entity):
            world.set_component(entity, p["name"], p["value"])

    elif t == "add_component":
        entity = p["entity"]
        if world.is_alive(entity):
            world.add_component(entity, p["name"], p["value"])

    elif t == "remove_component":
        entity = p["entity"]
        if world.is_alive(entity):
            world.remove_component(entity, p["name"])

    elif t == "damage_entity":
        entity = p["entity"]
        amount = p.get("amount", 1)
        if world.is_alive(entity):
            hp_comp = world.get_component(entity, "Health")
            if hp_comp is not None:
                hp_comp["hp"] -= amount
                world.set_component(entity, "Health", hp_comp)

    else:
        raise ValueError(f"Unknown command type: {t}")
