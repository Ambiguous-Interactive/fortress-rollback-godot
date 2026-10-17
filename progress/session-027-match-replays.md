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
  frames through `min(confirmed, current - 1)` from retained confirmed input, never predictions.
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
| Record after discard instead of before | Passes: confirmation never trails the discard floor, so the order is equivalent; the comment states this |

Limits: replays across native/browser builds, a format golden with provenance, and spectator or
seek support remain open under #45 and later tasks.
