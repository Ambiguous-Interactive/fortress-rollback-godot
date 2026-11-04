# Retrospective: client history acceptance

## Work under review

Session 153 advances #40 driver-only input construction, #45 coordinated-drop
recording acceptance and #47 long-lived spectator SDK-adapter acceptance.
An additive client capability, cross-subsystem witnesses and a review correction
trigger this retrospective.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Input bytes alone cannot prove disconnect behavior survives playback | `test_peer_drop_replay.gd`, `RecordingGame` and `disconnect_status` control: a valid recomputed input digest reaches state-checksum failure | Extend existing oracle-validation guidance with status-sensitive canonical state |
| An inherited fixture extension can break a different suite at parse time | Independent review of `test_peer_drop_backfill.gd` and the existing `_wide_mesh` override in `test_peer_drop_capacity.gd`; direct engine red control | Restore the shared entry point, separate the recording helper, and document override inspection in infrastructure guidance |
| A short SDK witness misses ring reuse and repeated pressure | `test_signalfish_spectator_host.gd`, `_reordered_recorded_history`:257 rows, repeated refusal and reordered/duplicate packets | Extend the existing canonical case; retain real-server/browser acceptance boundaries |

## Curation and pruning

Searched existing testing references before writing. Extended the existing
oracle-validation and infrastructure guidance instead of creating another skill.
The prior producer/decoder/player and source-freeze guidance remains correct.
Removed the incompatible fixture signature rather than updating its descendant
to accept unrelated replay arguments. No older knowledge claim became obsolete.
The SDK fixture remains explicitly separate from real network qualification.

## Verification and limits

Driver capability removal fails the intended assertion; direct pinned runs pass.
New drop cases pass with callback/expert playback and serialized controls. Fresh
review exposed the inherited fixture failure despite those focused successes.
Final frozen-source two-pin tests, complete independent review, harness/source
checks, CI and delivery evidence are recorded in the machine-local session log
and linked task issues. Broad parent acceptance stays open.

## Outcome

Retro: findings-acted.
