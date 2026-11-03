# Retrospective: local input and playback acceptance

## Work under review

This session adds the direct driver's byte-row convenience API, actual pinned
replay-width comparisons, authenticated spectator history acceptance and faster
filtered native checks. New capability and verification changes require this review.

Evidence includes both pinned native runners, actual replay oracles, runner
failure controls and the independent adversarial reviews. The session log is
machine-local at `progress/session-146-gameplay-progress.md`.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Merged result equality cannot prove that empty child work was avoided. | `scripts/run_godot_tests.py` already discards zero-match shards in `merge`. | Count real executable launches in the existing sharding control. |
| Capacity waiting can dominate an apparent speedup. | The first timing attempt included waiting; the repeated comparison starts at the engine version probe. | Extend existing infrastructure guidance to separate waiting and execution. |
| Convenience does not imply speed. | The paired driver benchmark preserves published checksums, but byte-row submission costs more than reused explicit wrappers. | Document convenience and bounded wrapper reuse without a speed or allocation claim. |
| Parallel authoring needs a shared source freeze. | Early diagnostic receipts rejected intervening edits; frozen native and oracle runs passed. | Retain existing source-freeze guidance; do not duplicate it. |

## Verification

Both Godot 4.3 and 4.7.2 pass 785 native cases with both repetition layers.
Both actual replay oracles pass 63 pinned-source scenarios and 378 Godot
observations per round, repeated twice. The added widths require eight named
workloads and actual high-byte/range controls.

The complete runner control suite passes 28 tests. Oracle tooling passes 115;
reference tooling passes 279 with ten expected skips; harness tooling passes 179.
Three fresh adversarial reviews report no actionable findings.

The filtered comparison uses the same source tree and four workers. Suite
launches fall from 262 to two; execution falls from 55.6s to 7.3s in one local
sample, with identical results. Host-capacity waiting is excluded. Raw local
measurements live at `.cache/scratch/session146-filter-benchmark/measurements.json`.
No portable timing threshold or broad CI speedup is claimed.

## Review repairs

Automatic review identified a combined-inventory timeout that reused a single
shard's deadline. A scripted two-second listing fails the previous one-second
budget while its instant test executions fit it; the same probe passes with a
sufficient control budget. A separate bounded `--inventory-timeout` preserves
execution limits and still rejects an explicitly short listing budget.

Executable fixture shebangs also split interpreter paths containing spaces.
The shared quoted fixture writer replaces every such occurrence and preserves
`__file__`, `sys.argv[0]` and literal arguments, including engine self-mutation
controls. Relative and symlink invocation identities are checked separately.
The wrapper adoption exposed raw-script replacement controls; those now mutate
the saved Python program and require each fault target exactly once. The
execution-budget negative control also proves that a larger discovery deadline
cannot lengthen actual test execution or preserve a prior success receipt.
Isolated ordinary/spaced interpreter controls establish the old
failure; the new spaced-and-quoted path control passes. Early scratch probes
reused a path prefix and produced a different startup error; isolated directories
corrected the instrument before interpreting that failure.

Replay acceptance now requires the exact diagnostic for every width mutation.
An unrelated-error control passes the former broad assertion and fails all 24
new assertions. Documentation distinguishes recoverable listing errors from
supervision failures. The existing infrastructure reference captures the
inventory-budget and executable-fixture lessons without adding another skill.

## Prune ledger

Extend the existing testing infrastructure reference in place. No new skill or
knowledge entry is needed. Existing measurement, capacity and source-freeze
rules remain valid. The job timing document replaces its pending partition
measurement claim with actual main-run evidence, preserving the changed-inventory
qualification. No other obsolete guidance was identified.

## Outcome

Retro: findings-acted

The original broad replay, spectator and driver acceptance remains tracked in
issues #45, #47 and #40. Browser-room and total-CI reductions remain in #164.
