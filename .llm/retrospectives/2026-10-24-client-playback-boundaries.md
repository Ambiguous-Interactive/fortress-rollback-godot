# Retrospective: client and playback boundaries

## Work under review

Driver cancellation, full ten-minute replay imports and bounded spectator startup versions.
Triggers: new facade capability and two production defects.
Evidence: deterministic red/green receipts and browser import JavaScript controls in
the machine-local session-071 progress log. Fresh adversarial reviews cover each runtime change.
Final delivery gates are recorded in that log and the linked session PR.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A valid producer output exceeded the consumer's limit. | `test_replay_viewer.gd` full_length_recording exceeds the former 1 MiB cap with 36,000 checksum rows. | Extend the infrastructure testing reference with maximum producer/consumer boundary checks. |
| Unbounded version shifts alias a valid version. | `test_spectator_stream.gd` authenticates versions 67, 131 and 195; the old publisher accepts them as version 3. | Bound versions before shifting; retain the existing determinism skill's shift-validation rule. |
| Cancellation can happen after an operation completes. | `test_driver_termination.gd` completion_handler verifies successful frame commit plus final terminal metadata. | Document cancellation as available during handlers; preserve ordinary reentry guards. |
| Native fixture isolation can call an unavailable Web API. | Candidate CI ownership job 120926080549 rejects `OS.get_process_id()` in the new replay test. | Use a native process suffix only outside Web, following the existing diagnostic-viewer fixture. |

## Prune ledger

Searched testing, transport, rollback and knowledge stores before adding guidance.
The producer/consumer boundary procedure was missing; update its existing infrastructure home.
Shift validation already has a canonical rule, so no duplicate guidance was added.
The infrastructure reference now explicitly requires platform-safe fixture naming and equal native/Web assertions.
Shared executable extraction conflicts are tracked with reproduction and acceptance in issue #197.
No old evidence was invalidated; older retrospectives remain historical records.
Verify-on-touch: harness lint/index/self-tests and applicable native/Web tests are required before landing.

## Outcome

State: findings-acted.
Broader upstream parity, spectator relay startup and release matrix requirements remain in their existing issues.
