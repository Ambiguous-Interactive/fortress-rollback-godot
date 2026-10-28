# Retrospective: recording and departure evidence

## Work under review

Session 102 advances driver equivalence (#40), actual recording applicability
(#45), and spectator source comparison and publication (#47/#131).
The production repair defers a spectator packet when an SDK getter opens a host
request. Source comparisons exercise real pinned APIs and retain their limits.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Constructed replay playback cannot establish recording semantics. | The old `scripts/oracle/rust/src/bin/replay.rs` directly constructed `Replay`; the new recording path invokes `with_recording(true)` and `into_replay()`. Actual delayed source exports include future rows without saved checksums. | Add all-local recording, independent delayed history and serialized playback; document source/product differences. Extend the existing oracle-validation reference. |
| An equal drop event does not prove agreement. | Initial cold review found that `test_driver_drop_parity.gd` read only `peer_dropped.frame` with equal survivor frontiers. | Read actual role-specific certification records; withhold real READY traffic and require pending agreement until release. Mutation controls remove retained evidence. |
| Reducing callback observations hides status and ordering failures. | Replay cold review found original callback records reduced to separate save-frame and advance-state lists. | Preserve the original ordered request records and compare input status, canonical saves and delayed samples independently. |
| Partition numbers do not identify workloads. | Adding the driver suite moved the paged Firefox workload; the existing rejection test failed with `ValueError not raised`. | Select the declared partition containing that workload. The same case fails before repair and passes afterwards. |
| Checking decimal/exponent markers does not preserve the integer domain. | Actual standalone probes accepted leading-zero numbers and unsigned negative zero in Godot while Rust rejected them. Duplicate decoded keys also survived Godot parsing. | Validate complete raw integer spelling, unsigned policy and decoded key identity; retain paired valid and malformed process controls. |
| SDK observation is a callback boundary. | `test_signalfish_spectator_host.gd` reproduces OFFER/ROW/END sends while `get_buffered_amount()` opens a host expert request. | Recheck host mutation ownership before sending; verify no send and exact retry after completion. |

## Evidence and review

Machine-local commands and receipts are recorded in
`progress/session-102-client-progress.md`. Focused driver and spectator suites
pass on both engine pins. Fresh reviewers examine scoped diffs without author
rationale; review findings receive separate implementation and fresh review.
The full session delivery gates include both native pins, exported ownership,
source-bound oracle receipts, source width, harness integrity and GitHub CI.

An initial review dispatch guessed workload dimensions incorrectly. It was
corrected to the actual documented recording corpus before adjudication; the
rejected larger claim was removed from PLAN. Future dispatches should quote the
actual acceptance excerpt, as the existing adversarial-review skill requires.

## Prune ledger

Updated the existing oracle-validation reference instead of adding another skill.
Clarified the old playback-only recording disclaimer to distinguish the new scoped
recording comparison. Retained source limitations and historical model controls;
no complete source parity or live spectator qualification is claimed.
Existing callback-boundary, agreement and numeric-token instructions already
cover the review findings and need no duplicate rules.

## Outcome

State: `findings-acted`. Remaining recording platforms and network scenarios,
spectator deployment, and broader driver acceptance remain in their original issues.
