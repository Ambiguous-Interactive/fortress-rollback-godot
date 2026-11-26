# Fortress Rollback Godot — Implementation Plan

## Purpose

Expose upstream Fortress Rollback to Godot games through GDScript, including
browser games using SignalFish. Priority order is
**correctness → simple client interface → measured performance**.
An optimization cannot weaken a correctness gate or obscure the client contract.

This file is a durable map: product decisions, architecture boundaries,
milestone gates and open-work navigation. GitHub issues own task detail,
dependencies, progress and acceptance. `docs/` owns contracts and evidence;
`.llm/` owns agent procedure; `progress/` is the machine-local session log.
Past work stays in git history, CHANGELOG and `.llm/retrospectives/`.

- Roadmap and backlog: [issue #2](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/2).
- Start point for the pinned baseline: [issue #12](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/12).
- Parent/child checklists provide the epic hierarchy. Task prerequisites, not
  issue-number order, determine readiness.
- Close a parent only after its applicable child tasks and gates are satisfied.

## Durable product decisions

| Decision | Contract |
| --- | --- |
| Runtime | The pinned Rust crate via GDExtension is the intended primary backend. The GDScript port remains the production backend during migration. |
| Engine floor | Godot 4.3; test the minimum and current stable release |
| First supported browser tier | 2–8 players; test every count in deterministic simulation |
| Real-browser scale points | 2, 4 and 8 peers, including mixed browsers |
| Browser transports | WebRTC plus SignalFish binary relay and fallback |
| Compatibility | Behavioral parity for supported features against a pinned upstream |
| Wire compatibility | The native backend uses the upstream protocol. Qualify mixed Rust/Godot sessions for the supported input schema and configuration. |
| Default API | Small save/load/simulate driver plus explicit expert request API |
| Feature delivery | Fixed-membership P2P first, then staged advanced parity |
| Verification | Rust oracle, independent invariants, properties and bounded formal checks |
| Distribution | Build native addon binaries in CI. Godot projects install prebuilt packages. Keep development and formal verification tools out of addon archives. |
| Upstream notifications | Weekly/manual workflow updating a deduplicated GitHub issue |
| Scene integration | Explicit state capture; automatic node replication is outside scope |
| Simulation ownership | The game owns deterministic simulation and complete serialization; the library supplies orchestration, validation and sync-test tooling |
| Time | Protocol time is separately injected and monotonic; browser suspension advances elapsed time truthfully |
| Storage | Validate configuration once and derive bounded storage from explicit limits; no intentional steady-state growth |

## Architecture boundaries

| Layer | Responsibility |
| --- | --- |
| Deterministic core | Input queues, prediction, confirmation, saved-state history, rollback |
| Session/protocol | Handshake, input exchange, ACKs, retries, pacing, lifecycle, checksums |
| Transport adapters | Bounded fake network, SignalFish relay and WebRTC byte delivery |
| Client driver | Ordered state callbacks, status handling and end-of-step notifications |

- One ordered request engine serves both facades. The driver and expert API
  must never implement separate rollback algorithms.
- Core classes are typed and SceneTree-independent; no hidden global state.
- Simulation advances in whole frames with stable player order and integer-first
  reference games. No network I/O, wall-clock reads or presentation work occurs
  inside simulation callbacks.
- SignalFish is optional: the core addon parses and runs without the SDK.
  Fixed-membership sessions terminate explicitly when recoverable history is lost.
- Frame/time domains, typed signatures and ownership: [ADR](docs/contracts.md),
  [local sessions](docs/session.md), [protocol](docs/protocol.md),
  [fixed peers](docs/peer-session.md), [handshake](docs/handshake.md).

## Native backend adoption

The [binding experiment](docs/experiments/upstream-binding.md) establishes
mixed-peer rollback and exported package feasibility for a two-player witness.
[Issue #444](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/444)
owns the transition. The upstream crate will own the rollback engine and wire protocol.
Godot retains game callbacks, the driver, and transport integration.

The [migration contract](docs/native-backend-migration.md) records the native
API, input schemas and migration paths. Qualify the driver, live transports
and prebuilt packages before switching the default. Each package installs the
GDScript runtime and its target-specific extension together. Remove each superseded GDScript
runtime path when its replacement passes acceptance. Retain the end-to-end
tests for supported behavior. The epics below track the existing port until
their acceptance criteria are met or explicitly superseded.

Qualify clean Web installs in [playable browser rooms](docs/experiments/upstream-binding.md#playable-web-rooms)
at 2, 4 and 8 peers on both Godot pins. Keep native WebRTC and SignalFish relay
acceptance tied to confirmed input, canonical state and observed routes.
Use a [focused hosted room](docs/native-backend-migration.md) to reproduce a
specific failure and the full profile to qualify the browser combination.

## Milestone map

| Epic | Work and acceptance gate |
| --- | --- |
| [E1 — Baseline and contracts](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/3) | Reproduce pins; inventory applicability; settle interfaces and evidence rules |
| [E2 — Verification infrastructure](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/4) | Real differential traces, independent oracle, shrinking and scoped model checks |
| [E3 — Representation experiments](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/5) | Measured integer, ownership, encoding and allocation contracts |
| [E4 — Rollback core](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/6) | Exact core behavior, bounded history and working sync-test sessions |
| [E5 — P2P protocol](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/7) | Confirmed agreement and bounded recovery across 2–8-peer fault scenarios |
| [E6 — SignalFish and browsers](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/8) | Real direct, relay and mixed-path sessions with safe lifecycle behavior |
| [E7 — Client API and release](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/9) | Usable driver/examples, measured performance and supported-release evidence |
| [E8 — Advanced parity](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/10) | Independently gated replay, spectators, delay, peer drop and hot join |
| [E9 — Maintenance](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/11) | Conservative drift classification, weekly reporting and reviewed upgrades |

E1 establishes the contracts. E2 and E3 can overlap after their prerequisites.
E4 builds on verified representations and comparison tooling; E5 adds networking.
E6 validates the browser target while E7's driver work proceeds against the core.
E7's release gate requires both protocol and real-browser evidence. E8 features
ship only after their individual gates. E9 starts once baseline and differential
infrastructure exist; it need not wait for advanced parity. Epic dependencies are
milestone gates, not blanket locks.

## Open work

GitHub issue state is authoritative. Every open task is reachable from the epic
checklists; the table names only the active acceptance threads. A task that is
already implemented but awaiting closure evidence still belongs to its issue.

| Track | Remaining outcome | Issues |
| --- | --- | --- |
| Native backend | Qualify live transports and packages, then retire covered runtime paths | [#444](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/444), [#452](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/452) |
| Coordinated drop | Live drop, room, process and commit/acknowledgement loss witnessed; pinned-source comparison and remaining schedules | [#48](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/48), [#166](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/166), [#188](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/188) |
| Replay and recording | Asymmetric and long recordings and final replay acceptance | [#45](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/45), [#256](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/256) |
| Spectators | Live relay/startup qualification, exported host/viewer recovery, redundant hosts | [#47](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/47), [#131](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/131), [#245](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/245), [#49](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/49) |
| Transport and release | Qualify legacy direct restoration, browser profiles and the first supported release | [#39](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/39), [#44](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/44), [#75](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/75) |
| Native browser compatibility | Qualify physical Safari and hosted WebKit close. Require causal close evidence on both pins. | [#457](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/457), [#459](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/459) |
| Native relay | Join the first unconfirmed warmup input and the last accepted packets before native expiry. | [#473](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/473), [#498](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/498) |
| Legacy browser evidence | Complete bounded Firefox relay and browser lifecycle qualification | [#38](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38), [#104](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/104) |
| Verification | Broader P2P time, delivery, profile and layout coverage | [#34](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/34), [#59](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/59) |
| Hot join | Reserved-slot admission and safe session reactivation | [#50](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/50) |
| Performance | Measured hot-path optimization without weakening equivalence | [#43](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/43) |
| Development feedback | Measure rollout latency and runner cost across qualifying revisions | [#451](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/451) |
| Maintenance | Drift review and upgrades, review availability, browser job time, install hangs | [#53](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/53), [#148](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/148), [#164](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/164), [#249](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/249), [#276](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/276), [#387](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/387), [#388](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/388), [#389](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/389) |

The drift carriers #387–#389 are reporting only; they never advance a pin.
The supported surface and explicit exclusions are in [docs/supported.md](docs/supported.md).

## Where truth lives

| Question | Authoritative place |
| --- | --- |
| Scope, priorities, milestone map | This file |
| Task detail, dependencies, status, acceptance evidence | GitHub [#2](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/2) and epics #3–#11 |
| Interface, frame/time, ownership contracts | [docs/contracts.md](docs/contracts.md), [docs/session.md](docs/session.md) |
| Protocol, handshake, peers, queues | [docs/protocol.md](docs/protocol.md), [docs/handshake.md](docs/handshake.md), [docs/peer-session.md](docs/peer-session.md), [docs/input-queue.md](docs/input-queue.md), [docs/input-exchange.md](docs/input-exchange.md) |
| Verification, evidence and performance claims | [docs/verification-policy.md](docs/verification-policy.md) |
| Pins, inventory and drift procedure | [docs/reference/README.md](docs/reference/README.md), [pins.json](docs/reference/pins.json), [INVENTORY.md](docs/reference/INVENTORY.md) |
| Supported surface and exclusions | [docs/supported.md](docs/supported.md) |
| Feature usage and examples | [docs/integration.md](docs/integration.md), [docs/spectators.md](docs/spectators.md), [docs/online-example.md](docs/online-example.md), [docs/peer-example.md](docs/peer-example.md), [docs/offline-example.md](docs/offline-example.md) |
| Differential and oracle evidence | [docs/oracle.md](docs/oracle.md), [docs/oracle-p2p.md](docs/oracle-p2p.md), [docs/oracle-replay.md](docs/oracle-replay.md), [docs/oracle-handshake.md](docs/oracle-handshake.md), [docs/peer-lifecycle.md](docs/peer-lifecycle.md) |
| SignalFish transports | [docs/signalfish-membership.md](docs/signalfish-membership.md), [docs/signalfish-relay.md](docs/signalfish-relay.md), [docs/signalfish-webrtc.md](docs/signalfish-webrtc.md), [docs/signalfish-fallback.md](docs/signalfish-fallback.md) |
| Durable lessons and history | [.llm/knowledge/](.llm/knowledge/), [.llm/retrospectives/](.llm/retrospectives/) |
| Agent procedure | [.llm/context.md](.llm/context.md), [.llm/skills/](.llm/skills/) |
| Session narrative | `progress/` (machine-local; never committed) |

Pins and provenance are recorded once in [pins.json](docs/reference/pins.json)
and [docs/reference/README.md](docs/reference/README.md). Do not duplicate
revisions here. Every imported fixture records its source revision and any
translation.

## Session loop and plan hygiene

1. State the hypothesis, observable contract and upstream evidence.
2. Demonstrate a meaningful failing case or negative control.
3. Implement the smallest complete change and run independent/differential checks.
4. Refactor or optimize only while preserving equivalence evidence.
5. Record commands, versions, seeds, measurements, limits and conclusions in the
   issue and session log; close only after acceptance passes.

Use [verification-policy](docs/verification-policy.md) for evidence fields and
[ship-session](.llm/skills/ship-session/SKILL.md) for delivery. Copy follows
[user-copy](.llm/skills/user-copy/SKILL.md); source lines are at most 180 columns.

Keep this file lean. Each session removes completed or obsolete entries and adds
new status to the owning issue or doc, never here. This file is capped at 180
lines by `scripts/llm/check_llm_file_lengths.py`; `make lint-llm` fails when it
grows. The map-not-log rationale and evidence are in
[.llm/knowledge/plan-hygiene.md](.llm/knowledge/plan-hygiene.md).
