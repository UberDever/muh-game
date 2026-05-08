Copy-paste spec for another AI:

````md
# Spec: Python POC for Game Runtime Architecture

Implement a small Python prototype of a game runtime with:

- ECS world storage
- main-thread frame orchestrator
- parallel ECS jobs
- deterministic event queue
- command buffer
- cooperative script coroutines
- background asset/IO service
- no graphics; print/debug-log simulation is enough

Use Python 3.11+ and stdlib only.

Do not use `asyncio`. We want explicit frame phases, not Python’s event loop.

---

## Goal

Build a runnable POC that demonstrates this architecture:

```text
Main thread:
  input/mock tick
  schedule parallel ECS jobs
  wait barrier
  merge thread-local events
  resume script coroutines
  process ordered events
  apply command buffer
  render/debug print

Worker threads:
  run pure-ish ECS jobs over stable world snapshot
  emit deferred events
  do not mutate world

Background threads:
  simulate asset loading / IO
  emit completion events
  do not mutate world

Scripts:
  run cooperatively on main thread
  can query stable world state
  can emit events
  can enqueue commands
  can await timer/event/asset
  cannot mutate ECS storage directly
````

---

## Non-goals

Do not implement:

* real rendering
* real Lua integration
* real physics
* networking
* complex ECS query optimizer
* hot reload
* real asset loading

Scripts should be Python generator coroutines that model future Lua coroutines.

---

## Required file layout

Preferred simple layout:

```text
runtime_poc/
  main.py
  ecs.py
  events.py
  commands.py
  jobs.py
  scripts.py
  background.py
  demo_game.py
```

Single-file implementation is acceptable only if still clean.

---

## Core concepts

### Entity handles

Use generational handles.

```python
@dataclass(frozen=True)
class Entity:
    index: int
    generation: int
```

World must reject stale handles.

---

### World / ECS storage

Implement `World` with:

```python
class World:
    def create_entity(self) -> Entity
    def destroy_entity(self, entity: Entity) -> None
    def is_alive(self, entity: Entity) -> bool

    def add_component(self, entity: Entity, name: str, value: Any) -> None
    def remove_component(self, entity: Entity, name: str) -> None
    def get_component(self, entity: Entity, name: str) -> Any | None
    def set_component(self, entity: Entity, name: str, value: Any) -> None

    def snapshot(self) -> WorldSnapshot
```

`WorldSnapshot` is read-only from user perspective.

Worker jobs and scripts must query snapshots or read-only APIs, not mutate `World`.

Components can be plain dicts/dataclasses:

```python
Position = {"x": 0.0, "y": 0.0}
Velocity = {"x": 1.0, "y": 0.0}
Health   = {"hp": 10}
Tag      = {"name": "enemy"}
```

Keep it simple.

---

## Events

Implement typed events:

```python
@dataclass(frozen=True)
class Event:
    type: str
    payload: dict
    source: str
    seq: int = 0
```

Examples:

```text
"enemy_near_player"
"damage_requested"
"entity_died"
"asset_loaded"
"play_sound"
```

Event ordering must be deterministic.

Suggested merge order:

```text
1. background completion events drained at frame start
2. worker job events, merged by registered job order
3. script events, merged by script id/order
4. event handlers process in FIFO order
```

---

## Command buffer

World mutation only happens through `CommandBuffer`.

Implement commands:

```python
@dataclass(frozen=True)
class Command:
    type: str
    payload: dict
```

Required command types:

```text
spawn_entity
destroy_entity
set_component
add_component
remove_component
damage_entity
```

`CommandBuffer.apply(world)` mutates the real world.

Scripts and events may enqueue commands.

No worker job may directly mutate `World`.

---

## Job system

Use `concurrent.futures.ThreadPoolExecutor`.

Implement:

```python
class JobSystem:
    def submit_frame_jobs(self, jobs: list[ECSJob], snapshot: WorldSnapshot) -> list[JobResult]
```

Each ECS job:

```python
@dataclass
class JobResult:
    job_name: str
    events: list[Event]
```

Jobs operate only on snapshot.

Required demo jobs:

### MovementScanJob

Reads `Position` and `Velocity`.

Does not mutate world.

Instead emits:

```text
"movement_update_requested"
```

or returns commands via event/command path.

For simplicity, this job may emit event:

```python
Event("move_requested", {"entity": e, "dx": vx, "dy": vy}, source="movement")
```

Then event processing converts it into a `set_component` command.

### EnemyAIScanJob

Reads enemy/player positions.

If enemy near player, emits:

```python
Event("enemy_near_player", {"enemy": enemy, "player": player}, source="ai")
```

### DeathScanJob

Reads Health.

If hp <= 0, emits:

```python
Event("entity_died", {"entity": e}, source="death_scan")
```

---

## Script system

Model Lua scripts as Python generators.

Each script is a `ScriptInstance`:

```python
@dataclass
class ScriptInstance:
    id: int
    owner: Entity | None
    coroutine: Generator
    wait_condition: WaitCondition | None
    alive: bool = True
```

Supported waits:

```python
@dataclass(frozen=True)
class WaitFrames:
    frames: int

@dataclass(frozen=True)
class WaitEvent:
    event_type: str
    entity: Entity | None = None

@dataclass(frozen=True)
class WaitAsset:
    asset_name: str
```

Script API:

```python
class ScriptAPI:
    def query_component(self, entity: Entity, component: str) -> Any | None
    def find_by_tag(self, tag: str) -> list[Entity]

    def emit(self, event_type: str, payload: dict) -> None
    def command(self, command_type: str, payload: dict) -> None

    def await_frames(self, n: int) -> WaitFrames
    def await_event(self, event_type: str, entity: Entity | None = None) -> WaitEvent
    def await_asset(self, asset_name: str) -> WaitAsset
```

Scripts are resumed only during the script phase:

```python
script_system.resume_runnable_scripts(snapshot, event_queue, command_buffer)
```

Script execution is sequential/cooperative:

```text
resume script 1
resume script 2
resume script 3
...
```

No script runs in worker threads.

No script directly mutates `World`.

---

## Background service

Use a background thread or thread pool.

Implement:

```python
class BackgroundService:
    def request_asset(self, asset_name: str) -> None
    def drain_completion_events(self) -> list[Event]
    def shutdown(self) -> None
```

Asset loading may be simulated with `time.sleep(0.05)`.

When done, background service emits:

```python
Event("asset_loaded", {"asset": asset_name}, source="background")
```

It must not resume scripts directly.

Scripts waiting on asset resume next script phase after completion event is merged.

---

## Frame orchestrator

Implement:

```python
class FrameOrchestrator:
    def run_frame(self, dt: float) -> None
```

Frame order must be exactly:

```text
1. drain background completion events
2. create stable world snapshot
3. schedule ECS jobs
4. wait for jobs
5. merge worker events
6. resume runnable scripts
7. process event queue in fixed order
8. apply command buffer to world
9. debug render / print world state
```

Important invariant:

```text
Only step 8 mutates the real World.
```

Exception: initial setup may mutate world.

---

## Event handlers

Implement event handlers as normal Python functions.

Required handlers:

```text
move_requested:
  enqueue set_component with updated position

enemy_near_player:
  enqueue damage_entity against player
  emit play_sound event

damage_requested:
  enqueue damage_entity

asset_loaded:
  wake scripts waiting on asset

entity_died:
  enqueue destroy_entity

play_sound:
  print/log sound request only
```

Handlers may enqueue commands.

Handlers may emit new events, but avoid infinite loops. For POC, process only events currently in queue plus newly appended events up to a safety limit, e.g. 100 events/frame.

---

## Demo scenario

Create:

```text
Player entity:
  Position(0, 0)
  Health(10)
  Tag("player")

Enemy entity:
  Position(3, 0)
  Velocity(-1, 0)
  Health(3)
  Tag("enemy")
```

Attach script to enemy:

```python
def enemy_script(api, enemy):
    yield api.await_asset("enemy_attack_animation")

    while True:
        pos = api.query_component(enemy, "Position")
        players = api.find_by_tag("player")

        if players:
            api.emit("damage_requested", {
                "target": players[0],
                "amount": 1,
                "source": enemy,
            })

        yield api.await_frames(2)
```

Background service should load `"enemy_attack_animation"` asynchronously after startup.

Run 10 frames.

Expected visible behavior:

```text
- background asset load completes
- enemy script starts after asset_loaded
- ECS jobs run on worker threads
- events are merged
- script emits damage_requested
- command buffer applies player damage
- debug output prints player HP decreasing
- no worker or script directly mutates world
```

---

## Debug output

Each frame should print concise logs:

```text
FRAME 3
  background events: 1
  worker events: 2
  scripts resumed: 1
  events processed: 4
  commands applied: 2
  player hp: 8
```

Also log thread names for worker/background jobs at least once, to demonstrate concurrency.

---

## Design constraints

Keep implementation boring.

Avoid:

* magic decorators
* global mutable service locator
* hidden mutation
* clever metaprogramming
* real async/await
* actor-style direct peer-to-peer messaging

Prefer:

* explicit frame phases
* explicit queues
* explicit command buffer
* deterministic merge order
* small dataclasses
* readable logs

---

## Success criteria

The prototype is successful if:

1. `python -m runtime_poc.main` runs a 10-frame simulation.
2. Worker ECS jobs run using `ThreadPoolExecutor`.
3. Background asset loading runs outside main frame execution.
4. Scripts are cooperative generator coroutines.
5. Scripts and jobs cannot mutate the live world directly.
6. All world changes go through command buffer apply phase.
7. Output clearly shows frame phases and deterministic order.


