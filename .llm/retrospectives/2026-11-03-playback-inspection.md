# Playback inspection

## Scope and evidence

This session advances driver, replay and spectator client flows in issues #40,
#45 and #47. The effects scene pauses and services individual ticks. Spectator
host pause lets queued inputs settle while viewers continue. Replay repetition
creates fresh playback lifetimes and revalidates the original recorded evidence.
The larger parity and live-network acceptance gates remain open.

Meaningful missing-capability controls fail before each feature. The existing
single-play, ordinary-service and running-host paths supply positive controls.
A fresh review of the integration change found a real paused-control defect:
`examples/integration/integration.gd` returned before refreshing disabled controls
when an external expert request finished. The new control-recovery assertions
fail before repair. Both pinned engines then pass all seven integration cases,
including actual prediction stalls, rollback and original canonical/effect history.

A separate fresh replay review requested terminal-checksum and input-digest
coverage. The added table checks clean repeated terminal completion and exact
failure boundaries. The complete replay/lifetime selection passes 21 cases with
zero engine errors. The deferred live GUI probe passes exactly 210 checks,
including real focus, pointer and keyboard dispatch for the new controls.
Screenshots show all three controls with the game boards visible.

Evidence: `.cache/session148-driver-refresh-red.log:5` records the two expected
readiness failures. `.cache/session148-driver-refresh-43.log:18` and
`.cache/session148-driver-refresh-472.log:17` record the seven passing integration
cases. `.cache/session148-replay-iteration3.log:45` records the 21 replay cases;
`.cache/session148-gui-iteration3.log:3` records `FORTRESS_REPLAY_NAVIGATION_OK 210`.
Reproduce the selections with the pinned engine as `godot`:

```sh
godot --headless --path . --script tests/runner/run_tests.gd -- --suite res://tests/unit/test_integration_demo.gd
godot --headless --path . --script tests/runner/run_tests.gd -- --suite res://tests/unit/test_replay_viewer.gd --suite res://tests/unit/test_replay_viewer_lifetime.gd
godot --headless --path . --script scripts/reference/replay_navigation_probe.gd
```

Screenshots: [effects](../../docs/images/session148-integration.png),
[spectator](../../docs/images/session148-spectator.png), and
[replay](../../docs/images/session148-replay.png).

Full frozen-source native and current-head browser/CI delivery remain pending
at artifact authoring. Final evidence belongs in the machine-local session log
and linked issue comments, not in a preemptive success claim here.

CI then found an existing lifecycle regression at
`tests/unit/test_example_scene_exit.gd:138`: skipping service preserved owned
state but left the scene result at OK instead of BUSY. The retained CI artifact
`ownership-reference-results-4.7.2-firefox-negative-part-2` in run 41685196214
records the exact failure. `.cache/session148-driver-busy-red.log` reproduces it.
The repair reports actual ownership without servicing simulation and keeps BUSY
presentation separate from a terminal stop. Both pins pass all eleven scene-exit
and integration cases in `.cache/session148-driver-busy-43.log` and
`.cache/session148-driver-busy-472.log`. This reinforces existing full-suite
verification guidance; no additional overlapping procedure is needed.

## Harvest and curation

| Finding | Action |
| --- | --- |
| Paused physics can strand controls disabled after expert ownership ends. | Extend GDScript style's scene ownership guidance to require readiness refresh without simulation service. |
| Parallel edits invalidate source-bound receipts even when assertions pass. | Existing testing infrastructure guidance already requires a coordinated source freeze; retain it and use one final qualification. |
| Repetition must cross terminal validation, not just the last input. | Keep terminal checksum and input-digest cases in the existing replay test table. |

## Prune and verification

The existing scene retry guidance remains correct; the readiness-refresh rule
extends it rather than introducing another skill. No competing guidance or
obsolete entry was identified. Generated skill descriptions and indexes do not
change. Source-width, harness checks and final delivery gates must run after
these edits. No format, source pin or release-parity claim changes.

Retro: findings-acted
