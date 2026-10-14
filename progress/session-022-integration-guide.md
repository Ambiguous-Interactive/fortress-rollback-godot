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
omitted from snapshots stops with `DESYNC`. Sixteen malformed snapshots are
rejected with complete state unchanged, including a future ring ID and a shot total
above one shot per player per frame.

Mutation controls, each restored afterwards:

| Mutation | Result |
| --- | --- |
| Remove the confirmation check | Lagged rows play wrong shots |
| Remove the pending-rollback clamp | Burst row plays a wrong shot after delivery |
| Play one frame early (`<= final + 1`) or late (`< final`) | Per-tick playback check fails |
| Resample input on every tick | Stalled rows stop with `INPUT_ALREADY_SUBMITTED` |
| Shrink the shot ring to three slots | Lost confirmed shots; four slots (the derived bound) pass |
| Remove ring-order, future-ID, total-bound or position lower-bound validation | Malformed snapshots load |

Earlier logs: `.cache/tests/session-022-ungated-effects-red.log` and
`.cache/tests/session-022-resample-red.log`.

Fresh adversarial review found the missing pending-rollback clamp, an untested
boundary, a vacuous lag-3 misprediction claim, incomplete validation and inaccurate
step-result advice. All were fixed and are covered by the controls above.
A second fresh review confirmed the ledger logic and found test-pinning and wording
gaps; those are fixed. One limit remains: a pending-rollback clamp one frame too
strict only delays a shot until the next step, and no scenario pins it.
The first resample control passed vacuously because test keys depended on frame;
stalled ticks now press different keys.

## Native suites

Before the review fixes, Godot 4.3 passed all unit, integration and determinism
categories, and 4.7.2 passed determinism. Later local 4.7.2 integration and 4.3
unit reruns hit the 120-second watchdog in existing WebRTC backlog suites while a
reviewer ran Godot concurrently; their cases did not fail. CI runs these with a
180-second budget. The new suite passes on both engines after every fix.

## PR corruption-control failure

PR run `38512087955` passed every job except SignalFish WebRTC 4.7.2. Its positive
five-room flow passed; the Python validator rejected the corruption control with
`rollback or confirmation missing`. The retained record shows one peer playing at
frame 39/confirmed 31 and the other failed with intended DESYNC (18) at frame 31,
confirmed 32, with 32 submitted samples.

The validator required `confirmed <= len(inputs) - 1` for every peer. The bridge
records inputs by scheduled frame, so that bound is right for a complete capture.
A desynced peer stops capturing at termination, so its last confirmed frame can
lack a captured input. For that peer only, the bound is now the session invariant
`confirmed <= frame + INPUT_DELAY` (delay 2); playing peers keep the strict bound.
Cursor Bugbot flagged an earlier looser draft that relaxed both peers.
The fixture accepts 108 and 109 for the desynced peer at frame 107, rejects 110,
and rejects 108 for a playing peer with 108 inputs. The old bound fails the valid
rows (`.cache/tests/session-022-confirm-bound-red.log`). The retained CI record
now reaches the intended `canonical prefix mismatch at frame 3`. All 72 reference
tests pass. No other probe bounds confirmation by sample count.

## Remaining scope

#41 stays open: clean-install command runs on both engines, SignalFish setup
consolidation and a playable input-driven effects scene remain. A1/A3 driver and
diagnostic gaps stay under #40/#42. Browser recovery work stays under #38/#75/#39.
