# Session 027 — Match recording and replay

## Scope and baseline

Started 2026-10-17 at 05:04 UTC with a two-hour limit. Main was clean at
`be522d0e218ab2467dab7d99ec9b8f588e03964d` with all three main workflows green and no open PRs.

Triage ranked open issues by player impact. #104 (eight-player Firefox CI) was examined first:
its preserved failure diagnostics show every page visible and focused, rendering about 8–10 frames
per second while eight exports share two CPUs. It is runner starvation in the test host, not
behavior a player sees, so it stays open with its existing acceptance. This session delivers the
first slice of #45: recording a match and playing it back.

## Upstream contract

Pinned `src/replay.rs` and `src/sessions/replay_session.rs` record confirmed inputs per frame with
optional checksums, validate frame/player counts, and play back with a save request before each
advance when validating. Skipped frames keep alignment with default inputs.

## Implementation

- `FortressReplay`: versioned little-endian format (magic, version, players, width, frames,
  skipped, then per-frame inputs and an optional 16-byte checksum). `decode` checks the declared
  frame count against the bytes present before allocating, rejects trailing bytes and leaves the
  replay unchanged on failure.
- `config.replay_max_frames` turns recording on. After each completed batch the session records
  frames through `min(received by every player, current - 1)` from retained actual input, never
  predictions. Received input is final; the mesh confirmation limit only tracks peer acknowledgement.
  Recording keeps the first frames and stops when full. `session.replay()` and `peer.replay()`
  return copies.
- `FortressReplayPlayer` steps the game's own callbacks. It stops at the first checksum mismatch
  with `DESYNC`; upstream queues an event and continues. This difference is documented.

## Evidence

`tests/unit/test_replay.gd` records five matches (on time, late corrections, bursts with stalls,
input beyond the prediction window, sync-test). Each must record actual inputs for every simulated
frame, round-trip its bytes, validate every checksum and reproduce the reference final state.
It also covers rules that diverge at frame 40 (`DESYNC` at 41), callback failure, every truncation,
nine malformed header/flag rows, trailing bytes, caller size limits and recording bounds.

Mutation controls on Godot 4.3:

| Mutation | Result |
| --- | --- |
| Record through `current - 1`, ignoring confirmation | Fails actual-input, skip and checksum checks in three late-input rows |
| Accept trailing bytes | Fails trailing-byte and failed-decode checks |
| Record after discard instead of before | Passes: receipts never trail the discard floor, so the order is equivalent; the comment states this |
| Record through the mesh confirmation limit (first draft) | Fails the lockstep case: 30 frames, nonzero skipped, wrong final state |

## Review

A fresh adversarial review reproduced lost frames in lockstep peer sessions: the first draft
recorded only through the mesh confirmation limit, which trails receipts while lockstep discards
each simulated frame. Recording now follows receipts, and `lockstep_confirmation_limit` fails
before the repair and passes after it. The review also led to slice-based decoding, type-checked
callback results with one exit path in the player, and documentation for `skipped_frames()`.
A second fresh review confirmed these repairs, including that recorded checksums never precede a
correction and that no unrecorded frame reaches the discard floor. Its two low findings are fixed:
the lockstep case now requires all thirty checksums, and the demo shows a refused replay start.
Full unit and determinism categories pass on both native pins for the reviewed code.

## Playable demo

The shots example records its match. **P** pauses it and replays the confirmed frames from a fresh
game, checking every checksum. `replays_corrected_match` plays a rolled-back match and requires the
replay to end on the live corrected state.

Limits: replays across native/browser builds, a format golden with provenance, and spectator or
seek support remain open under #45 and later tasks.

## Retrospective

The [retrospective](../.llm/retrospectives/2026-10-17-match-replays.md) adds the headless
`class_name` and constant-expression rules to the GDScript style skill.
Retro: findings-acted.

## Online diagnostic validator

Two later PR runs failed `Play the shipped online example` with `diagnostic integer outside domain`
(4.3 job 117318405145; 4.7.2 in run 39005643266), after the first head passed. Replaying the
validator over the downloaded 4.3 evidence shows the first trace row at frame 61 where 60 was
expected. That download was taken at a prediction stall: current 180, confirmed 172. The stalled
step had saved the state at frame 180 before simulating it, so the trace correctly ends with a
state-only row at `current_frame`. The validator assumed the window always ends at
`current_frame - 1`, so it failed whenever capture landed on a stall. Recording is disabled in the
online example, so this branch does not change that path.

The validator now accepts exactly two shapes: a window ending at `current_frame - 1`, or one ending
at the saved boundary whose only inputless row is last. Payload accounting counts that row without
inputs. A stall-boundary regression fails before the change and passes after it, with five rejected
variants. The actual failing CI evidence now validates, and all 90 reference tests pass with three
environment skips.
