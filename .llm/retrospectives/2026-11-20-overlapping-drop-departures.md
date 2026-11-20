# Retrospective: 2026-11-20 overlapping drop departures

## Work Under Review

- Scope: `docs/peer-lifecycle.md`, `docs/supported.md`, and the new
  `tests/unit/test_peer_drop_simultaneous.gd` (4 files, 120 inserted lines).
- Trigger: new capability evidence for a named coordinated-drop case and a
  release-declaration correction; the change is below the large-change line.
- Evidence base: `make gate`, both pinned engines running every
  `tests/unit/test_peer_drop_*.gd` suite, the drop-history differential
  receipt, and the reference ownership/replay-download tooling tests.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Two automatic departures that overlap while the first barrier is open terminate every survivor with `participant_lost`, because the second departing peer is still a member of the frozen participant set. This is safe and must stay explicit; the serial second-departure case remains the supported path. | fact | `tests/unit/test_peer_drop_simultaneous.gd` fails without the participant check and passes on both pins with `mesh.reasons == participant_lost x3` and `frozen_frame == -1`; documented in `docs/peer-lifecycle.md` |
| 2 | The supported-browser table had drifted two Chromium majors and two Firefox releases behind `docs/reference/pins.json`, and described Firefox as unqualified while both Firefox matrices run nightly. | fact | `docs/supported.md` versus `docs/reference/pins.json` (`chromium_version 156.0.8078.4`, `firefox_version 157.0`); `.github/workflows/nightly.yml` owns both Firefox matrices |
| 3 | A test fixture cannot raise `drop_barrier_timeout_us` above `disconnect_timeout_us`; `L.Options.valid_options` refuses the configuration and the mesh builds with null cores. The failure reads as a generic `INVALID_ARGUMENT`. | fact | `addons/fortress_rollback/protocol/lifecycle_types.gd:32`; the first scratch build at 700000/400000 returned `configure=1` |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Recorded the overlapping-departure fail-closed rule beside the existing participant-loss rule. | `docs/peer-lifecycle.md` | `make lint-llm` |
| 2 | Replaced the stale browser versions and tier wording; named the mixed-browser ICE gap and its owning issue. | `docs/supported.md` | `make lint-llm` |
| 3 | Added the five-peer regression with the real barrier and participant-loss assertions. | `tests/unit/test_peer_drop_simultaneous.gd` | new suite passes twice on Godot 4.3 and 4.7.2 |

## Prune Ledger

- Retired / merged / fixed at source: corrected the stale `docs/supported.md`
  browser rows in place rather than adding a second status page.
- Verify-on-touch: `make gate`, `python3 scripts/reference/test_ownership_probes.py`,
  `python3 scripts/reference/test_replay_download.py`, and
  `make drop-history-probes` were re-run for this change.

## Outcome

- State: `findings-acted`
- Follow-ups: live missing-history transfer and exported rollback-time/second
  departure witnesses remain in #166/#188; the mixed Chromium/Firefox ICE setup
  gap remains in #104/#39.
