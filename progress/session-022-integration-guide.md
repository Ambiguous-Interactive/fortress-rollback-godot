# Session 022 — Integration guide and confirmed effects

## Scope and starting state

Started 2026-10-14 at 03:42 UTC; target duration is under two hours.
Main starts at `07638bfc9b69fc6d9f953053c0dbb81b51f24f35` with a clean worktree,
no open PRs and green merge-triggered workflows. Session 021 is fully delivered.

The GOAL asks for user-facing progress. [#41](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/41)
(A2) still lacked a guide for integrating rollback into an arbitrary game and any
example of rollback-safe effects driven by input. Every existing example derives
its effects from snapshotted randomness only, so prediction can never invent or
remove one. Real games fire, jump and score from input. A naive presentation
plays a predicted shot that the remote player never fired.

## Hypothesis and contract

An effects ledger plays a shot only when its frame is final:
`frame <= min(confirmed_frame, pending_rollback_frame - 1)` and `frame < game.frame`.
It then plays exactly the shots of an uninterrupted replay of actual inputs, each
on the first tick its frame is final. Shot IDs derive from frame and player and
increase with frame, so one high-water mark prevents repeats. A frame loop that
samples once per frame and resubmits that sample while stalled never hits
`INPUT_ALREADY_SUBMITTED`.

## Changes

- `examples/integration/game.gd`: two players, one input byte (left, right, fire),
  six-frame cooldown and an eight-slot snapshotted shot ring. Snapshots are 120
  fixed-width bytes. Loading validates every field, the shot total bound and ring
  order before changing state. MD5 supplies the 16 checksum bytes.
- `examples/integration/loop.gd`: external-input session for one local player,
  retained stalled sample, effects reconciliation after `OK`/`PREDICTION_STALL`.
- `examples/integration/effects.gd`: once-only ledger gated by confirmation and
  pending rollback.
- `docs/integration.md`: install, input packing, snapshot completeness, simulation
  rules, step results, stalls, errors, presentation, sync-test and Rust migration.
- README, PLAN.md entry points, CHANGELOG and rollback-fundamentals link the guide.

## Evidence

`tests/unit/test_integration_example.gd` drives the loop with remote input late by
0, 3, 3 in six-tick bursts, 7 and 12 ticks. Bursts and the 12-tick row exceed the
eight-frame window and stall; stalled ticks press different keys. The remote player
releases fire while its cooldown is ready, so every lagged row predicts shots that
were never fired. The test also reconciles right after each delivery, before the
step. After every tick, played IDs must equal the replay's shots whose frames are
final. After a final delivery tick, canonical bytes must equal a direct replay
without a session. Each lagged row must roll back. Sync-test with the cooldown
omitted from snapshots stops with `DESYNC`. Fifteen malformed snapshots are
rejected with complete state unchanged.

Mutation controls, each restored afterwards:

| Mutation | Result |
| --- | --- |
| Remove the confirmation check | Lagged rows play wrong shots |
| Remove the pending-rollback clamp | Burst row plays a wrong shot after delivery |
| Play one frame early (`<= final + 1`) or late (`< final`) | Per-tick playback check fails |
| Resample input on every tick | Stalled rows stop with `INPUT_ALREADY_SUBMITTED` |
| Shrink the shot ring to three slots | Lost confirmed shots; four slots (the derived bound) pass |
| Remove ring-order or position lower-bound validation | Malformed snapshots load |

Earlier logs: `.cache/tests/session-022-ungated-effects-red.log` and
`.cache/tests/session-022-resample-red.log`.

Fresh adversarial review found the missing pending-rollback clamp, an untested
boundary, a vacuous lag-3 misprediction claim, incomplete validation and inaccurate
step-result advice. All were fixed and are covered by the controls above.
The first resample control passed vacuously because test keys depended on frame;
stalled ticks now press different keys.

## Remaining scope

#41 stays open: clean-install command runs on both engines, SignalFish setup
consolidation and a playable input-driven effects scene remain. A1/A3 driver and
diagnostic gaps stay under #40/#42. Browser recovery work stays under #38/#75/#39.
