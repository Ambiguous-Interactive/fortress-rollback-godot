# Retrospective: 2026-10-17 parallel suites, receipts and replay v2

## Work under review

Session 030 parallelizes the Godot test launcher and CI jobs, closes the launcher receipt gap (#103),
adds replay format version 2 (#45) and compares delay changes with the pinned upstream (#46). The
[session log](../../progress/session-030-parallel-suites-and-replay-v2.md) owns commands, timings and
review evidence.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Most CI wall time was serial steps that share no state, not slow tests. | Step timings: one 15-minute Godot step; the unit suite was 325s of it. | Split jobs by part and sharded suites: Reference Baseline 17m26s → 11m51s, local unit 203s → 48s. |
| A sharded runner can silently reorder records. | The new jobs-1-vs-4 control failed on its first run: shards kept argument order, the engine sorts. | Shards sort, and the merged result goes through the same validator, so duplicates still fail. |
| The #103 receipt gap also existed in a launcher the issue did not list. | Review found `run_godot_tests.py --results` kept a stale pass on rejected arguments. | Fixed with a red/green control. Sweep every receipt writer, not only the listed ones. |
| An oracle differential found a production bug that unit tests missed. | Godot sent one packet per gap frame after a raise; upstream sends one. | Fixed in `submit_frames`. Differential rows are worth the Rust driver work. |

## Prune ledger

The testing skill's local-iteration paragraph now describes sharded `make test-godot` instead of
recommending a single focused suite as the main speedup. The test-runner guide's `FILTER=restore`
example matched no case and was replaced.

## Outcome

- State: `findings-acted`.
- Follow-ups: #45 keeps the native/browser replay comparison and seek rows; #104 is unchanged.
