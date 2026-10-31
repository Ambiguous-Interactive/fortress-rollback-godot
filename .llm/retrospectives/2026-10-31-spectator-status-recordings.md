# Spectator status retirement and exported recordings

## Evidence and decisions

| Finding | Evidence | Action |
| --- | --- | --- |
| Terminal status detection did not retire buffered playback | The status-first room-change probe reported WRONG_STATE while the retained driver advanced frame 0; poll-first stopped it | Retire only committed failures in the captured bridge revision; preserve recursive checks and independently replaced sessions |
| Existing getter matrix treated status retirement differently | The player/config mutation cases explicitly excluded status from termination expectations | Correct those expectations and add status-first playable-row, queued-row, pending-acceptance and active-view controls |
| Matching synthetic engine strings hid incompatible producer formats | First actual Chromium recording completed but the independent validator rejected CLI version text versus replay metadata | Capture exact native version-dictionary identity and require one marker; retain strict recording metadata comparison |
| Short exported recordings extend an existing transport witness | Mixed rooms already own original inputs, sockets, rollback and teardown evidence | Reuse those rooms and validate each endpoint’s own decoded export; keep long-match/refusal/source gaps explicit |

## Verification entry points

- Spectator regression: `tests/unit/test_signalfish_spectator_relay.gd`, `status_lifetime`.
- Exported recording helper: `scripts/reference/browser/webrtc_recording.gd`.
- Independent byte/engine controls: `scripts/reference/test_webrtc_recording.py`.
- Exported runner: `scripts/reference/signalfish_webrtc_probe.py`, labels
  `mixed`, `mixed-default` and `mixed-close`, both pinned engines.
- Exact run receipts, red/green logs and delivery state are recorded in the
  machine-local session 132 progress log and linked issues #284/#256/#75/#45.

## Distill and prune

Updated the existing networking skill with committed-status ownership retirement.
Updated existing browser testing guidance with the actual engine-metadata boundary.
No new skill or overlapping procedure was added. Existing recursion, replacement,
first-cause, transport teardown and source-parity guidance remains applicable.
No stale claim is removed without replacement evidence. No whole-tree scratch or
per-session Rust build was created; existing verified server/browser tools are reused.

Retro: findings-acted
