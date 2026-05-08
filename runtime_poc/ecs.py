"""ECS world storage with generational handles."""

from __future__ import annotations

import copy
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class Entity:
    """Generational entity handle."""

    index: int
    generation: int


class World:
    """Mutable ECS storage. Only CommandBuffer.apply() should mutate after setup."""

    def __init__(self) -> None:
        self._generations: list[int] = []
        self._alive: list[bool] = []
        self._components: list[dict[str, Any]] = []  # index -> {name: value}
        self._free: list[int] = []

    # --- entity lifecycle ---

    def create_entity(self) -> Entity:
        if self._free:
            idx = self._free.pop()
            self._alive[idx] = True
            e = Entity(idx, self._generations[idx])
            return e
        idx = len(self._generations)
        self._generations.append(0)
        self._alive.append(True)
        self._components.append({})
        return Entity(idx, 0)

    def destroy_entity(self, entity: Entity) -> None:
        self._validate(entity)
        self._alive[entity.index] = False
        self._generations[entity.index] += 1
        self._components[entity.index].clear()
        self._free.append(entity.index)

    def is_alive(self, entity: Entity) -> bool:
        if entity.index < 0 or entity.index >= len(self._generations):
            return False
        return (
            self._alive[entity.index]
            and self._generations[entity.index] == entity.generation
        )

    # --- components ---

    def add_component(self, entity: Entity, name: str, value: Any) -> None:
        self._validate(entity)
        self._components[entity.index][name] = value

    def remove_component(self, entity: Entity, name: str) -> None:
        self._validate(entity)
        self._components[entity.index].pop(name, None)

    def get_component(self, entity: Entity, name: str) -> Any | None:
        self._validate(entity)
        return self._components[entity.index].get(name)

    def set_component(self, entity: Entity, name: str, value: Any) -> None:
        self._validate(entity)
        if name not in self._components[entity.index]:
            raise KeyError(f"Entity {entity} has no component '{name}'")
        self._components[entity.index][name] = value

    # --- snapshot ---

    def snapshot(self) -> WorldSnapshot:
        """Deep-copy current state into a read-only snapshot."""
        snap_gens = list(self._generations)
        snap_alive = list(self._alive)
        snap_comps = [copy.deepcopy(c) for c in self._components]
        return WorldSnapshot(snap_gens, snap_alive, snap_comps)

    # --- internal ---

    def _validate(self, entity: Entity) -> None:
        if not self.is_alive(entity):
            raise ValueError(f"Stale or invalid entity handle: {entity}")

    # --- query helpers (used by snapshot too) ---

    def all_entities(self) -> list[Entity]:
        result: list[Entity] = []
        for i, alive in enumerate(self._alive):
            if alive:
                result.append(Entity(i, self._generations[i]))
        return result


class WorldSnapshot:
    """Read-only deep copy of World state."""

    def __init__(
        self,
        generations: list[int],
        alive: list[bool],
        components: list[dict[str, Any]],
    ) -> None:
        self._generations = generations
        self._alive = alive
        self._components = components

    def is_alive(self, entity: Entity) -> bool:
        if entity.index < 0 or entity.index >= len(self._generations):
            return False
        return (
            self._alive[entity.index]
            and self._generations[entity.index] == entity.generation
        )

    def get_component(self, entity: Entity, name: str) -> Any | None:
        if not self.is_alive(entity):
            return None
        return self._components[entity.index].get(name)

    def all_entities(self) -> list[Entity]:
        result: list[Entity] = []
        for i, alive in enumerate(self._alive):
            if alive:
                result.append(Entity(i, self._generations[i]))
        return result
