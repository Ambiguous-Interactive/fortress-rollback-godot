# Session 023 — Playable rollback-safe effects

## Scope and starting state

Started 2026-10-16 at 00:12 UTC; target duration is under two hours.
Main starts at `0f3831c0d6464a54dd0c4d415e2242965bebabe2`, clean, with no open PRs.
All three merge-triggered workflows are green. Previous session work is delivered.
[#41](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/41)
still lacked a playable demonstration of input-driven rollback-safe effects.

## Contract and implementation

The scene reuses the integration guide's existing Game, Loop and Effects.
The player moves with A/D or arrows and fires with Space. A scripted remote
player releases fire while cooldown is ready, making late input produce phantom
predicted shots. Keys 1/2/3 select delivery lag 0/3/12; R starts a fresh match.
Delivery runs in process. This does not claim internet or browser release coverage.

`demo.gd` samples each remote frame once and schedules it against a monotonically
advancing controller tick. Stalls never stop delivery. Lowering lag retains old
deadlines and preserves FIFO input order. The existing loop retains local samples
while stalled. Pending input stays bounded (13 maximum); recent confirmed effects
retain 32 IDs. Diagnostic load/stall counts stay outside snapshotted game state.

Hollow flashes derive from corrected game state. Filled pulses are emitted by the
existing confirmation/pending-rollback-gated ledger and deduplicated by stable ID.
The renderer expires pulses after 18 controller ticks. Restart replaces the entire
session, game, sample queues and ledger, then clears the renderer's pulse history.

## Validation

The new controller suite drives six scenarios: each initial lag with and without
live changes, including both orders of 3/12 changes while old deliveries remain.
An uninterrupted game fed actual held local input and independently derived
remote input supplies expected canonical bytes and shot IDs. Every tick checks
exact confirmed effect counts and bounded ordered suffixes, delivery due frames,
queue size and clocks. Final drain compares complete canonical state and effects.
Rows require actual phantom predictions, rollback loads and stalls where applicable.
Reset tests start from live queued input and played effects, then compare a fresh
match. Invalid lag requests preserve the old match.

Focused suites pass on Godot 4.3 and 4.7.2 with both fresh-process and in-process
repetition:

```sh
make test-focus GODOT=.cache/reference/editors/4.3/Godot_v4.3-stable_linux.arm64 SUITE=res://tests/unit/test_integration_demo.gd
make test-focus SUITE=res://tests/unit/test_integration_demo.gd
```

Mutation controls, restored afterward:

| Mutation | Intended failure |
| --- | --- |
| Resample a remote frame every stalled tick | Pending queue 9 versus expected 8 |
| Remove recent-effect eviction | Bounded effect-history assertion |
| Count an effect twice | Actual count 4 versus expected 2 |
| Keep pending deliveries on reset | Pending input 8 versus expected 0 |

The first resampling mutation passed despite equal gameplay bytes: remote input
delivery is idempotent. The suite now checks an independent delivery schedule,
exact queue occupancy and confirmation timing. This strengthens the behavioral
contract beyond final-state equality.

The documented clean-project commands were run with only the addon, integration
example and project file copied into a temporary directory. Fresh import, direct
scene launch and actual engine input/fire/lag/reset checks pass on both pins.
Logs: `.cache/tests/session023-clean-{4.3,4.7.2}-{import,scene,input-reset}.log`.
The first draft tried copying a nonexistent icon; the executed commands are fixed.

An Xvfb OpenGL render on Godot 4.7.2 injected real engine key events: Space+D,
12-tick delay, then restart. Before restart the scene reports frame 112,
confirmed 104, 50 rollback loads, 68 stalled ticks and 32 confirmed effects.
Restart clears pulses, effect count and deduplication. Screenshot:
[`integration-effects.png`](../docs/images/integration-effects.png).
Rendering log: `.cache/tests/session023-render.log`. The headless container lacks
an audio device; Godot falls back to dummy audio. The example uses visible pulses.

Full Godot 4.3 unit coverage passes: 221 cases, repeated in fresh processes.
`make lint-source` checks 244 source files at maximum 180 columns.
Harness generation/lint and all 99 harness tests pass.

## Review and remaining work

Main-thread review checks the complete diff and existing Game/Loop/Effects contract.
Two fresh adversarial reviewers examined all six rubric surfaces and reported no
actionable findings. Reviews are static; runtime evidence is listed separately.
The second pass includes the final scheduling assertions found by mutation testing.

Clean-project browser onboarding now has detailed acceptance in
[#96](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/96),
linked to #41; #38/#75 retain advanced transport recovery and #39 the browser matrix.
No new runtime core, protocol or snapshot format is introduced.

Retro: findings-acted.
