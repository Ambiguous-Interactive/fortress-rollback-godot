# Retrospective: recording API and relay refusal acceptance

## Work under review

Session 128 adds manual/core-driver recording comparisons and a three-peer
native relay recording witness. The new verification capability triggers this
retrospective. Evidence comes from the source-bound replay launcher, native unit
receipts, an isolated production-relay mutation and fresh adversarial review.

## Findings

| Finding | Evidence | Disposition |
| --- | --- | --- |
| Existing recording acceptance exercised the callback driver, leaving manual execution unverified for the same long correction history. | `tests/oracle/replay_remote_trace.gd`; the base observer rejects `--expert`. | Added a separate manual request consumer and independent call/history comparisons. |
| Prediction stalls and SDK send refusal require different observations. | `tests/unit/test_relay_recording.gd` records actual SDK refusals and compares exact retried envelopes. | Added the native relay witness; retained real server/browser limits. |
| Initial service bounds were too short to complete the workload. | The first relay run reached frames 235/235/239; its 32 ms tail omitted the default 200 ms endpoint retry interval. | Corrected the test schedule; no production change followed from this instrument failure. |
| Active-pressure snapshot assertions can pass vacuously if only final recovery finds eligible rows. | Fresh review identified the missing observation gate in `tests/unit/test_relay_recording.gd`. | Added per-peer post-wrap comparison and correction assertions before releasing pressure. |
| A broad `RefCounted` array hid the manual consumer method contract from static checking. | Automatic PR review identified `manuals` in `tests/oracle/replay_remote_trace.gd`. | Applied the existing static-typing rule with `Array[Manual]`; both pins execute the terminal-pressure history. |
| One refusal does not prove sustained transport pressure. | A later outside-diff PR comment identified the nonzero-only `refused` assertion. | Require multiple refusals and successful retries, including refusals after queue wrap. |
| Equal retried bytes alone do not prove that the original refused head stayed queued. | A later outside-diff PR comment identified the missing immediate occupancy assertion. | Assert stable pending packet/byte counts and zero accepted sends at each refusal. |
| Dropping refused packets can leave plausible but incomplete replay history. | The isolated relay mutation fails exact-retry checks and exports 256 rows instead of 257. | Kept exact packet retries and finalized recording completeness as separate assertions. |

## Curation and pruning

The existing testing skill already requires reached-workload assertions and
independent validation of instruments. Its oracle reference requires measured
inventories, original canonical histories and owned-format recording playback.
The networking skill already requires exact refused-head ownership and outgoing
service under pressure. These rules were sufficient; duplicating them would add
no durable guidance. The new evidence is documented in
[the replay guide](../../docs/oracle-replay.md).

No skill, knowledge entry or rule was retired. No contradictory guidance was
found. Broader source recovery-only, server/socket, browser and complete release
gates remain open in #256, #253 and their parent tasks.

## Outcome

No new general procedure was needed. Existing guidance was applied and its
verification coverage expanded. Source-width, harness and final delivery gates
are recorded in the local session log and linked issue/PR evidence.

Retro: findings-acted
