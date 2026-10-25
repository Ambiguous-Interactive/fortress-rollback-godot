# Retrospective: terminal replay capture and spectator startup

## Work under review

Session 083 adds explicit replay-boundary SAVE capture, optional FRRP v6 terminal checksums,
callback/expert completion validation, actual pinned spectator startup comparisons and aligned full-suite watchdogs.
The trigger is a new portable format plus source/model verification work.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Input digests and N pre-input checksums cannot detect a simulation difference caused only by the last input. | `tests/unit/test_replay_terminal.gd:_validation` pairs historical completion with terminal-boundary failure. | Added the terminal coverage procedure to the rollback skill. |
| A synchronous replay export cannot create trustworthy application state evidence. | `session.gd:begin_capture_replay_boundary` requests an actual SAVE and refuses predicted or capped-state mismatch. | Added an explicit capture operation; retained historical format semantics. |
| A model sentinel rule can erase real startup backlog. | Original spectator startup traces still reject at the pinned counterexample while the separately anchored runtime-aligned relation passes. | Kept the original model, observations and controls; changed only the declared model relation. |
| A focused budget does not justify the full-suite budget. | Issue 210 retains failed 120-second receipts, successful focused controls and the existing CI 180-second contract. | Aligned only `test-godot`; focused and changed-suite budgets remain distinct. |

The first new replay probe used a nonexistent assertion helper and then a numeric expired-view expectation.
Those instrument failures were corrected before accepting evidence. The meaningful baseline red reports only
missing capture APIs; the final tests use the actual snapshot status enum. A driver helper name also collided
with a test subclass and was renamed before full verification. No unrelated parse failure is counted as a regression proof.

## Verification and review

- Historical v1-v5 golden bytes compare exactly with the base revision; v6 has an independent Python golden.
- Both callback and expert playback run all three portable versions against actual pinned Rust observations.
- The 55-case replay corpus includes an independent 12-workload terminal acceptance gate and rejection controls.
- Correction and drop terminal tests pass twice on both verified native pins.
- Fresh adversarial review requested on the final runtime, format, tooling and documentation diff.
- The spectator work has an independent adversarial review with no actionable findings.
- Full frozen-source, browser, CI and delivery evidence belongs in the machine-local session log and linked task issues.

## Prune ledger

Updated stale replay-oracle counts and completion descriptions in `docs/oracle-replay.md`.
Kept the existing oracle-validation startup-observation rule; a second skill entry would duplicate it.
No skills or knowledge files were retired. Broad replay, spectator and release parity claims remain gated by their original issues.

## Outcome

State: `findings-acted`.
