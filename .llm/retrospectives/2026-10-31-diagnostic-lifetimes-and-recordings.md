# Retrospective: diagnostic lifetimes and recordings

## Work under review

Session 124 carries forward the online cleanup witness repair (#267), protects
diagnostic playback ownership (#268), extends asymmetric recording evidence
(#256/#45), and repairs the slow cache scan (#264).
The triggers are callback cancellation, a main-CI incident and measured tooling
work. Candidate delivery evidence belongs in the issues and machine-local
`progress/session-124-gameplay-progress.md`.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Cleanup and the first observed failure are different evidence | The old online validator rejects stopped counterparts before canonical comparison; all 36 repaired focused tests pass | Carry forward the reviewed repair, preserving the actual desync requirement |
| Diagnostic playback missed the callback ownership rule already used by replay | Three baseline lifetime cases fail without engine errors; 12 diagnostic cases pass on both pins after repair | Guard viewer controls, retire replaced players, and expire active views on cancellation |
| Unequal recovery needs its own captured final boundary | Both engines export and replay all 257 original rows after different recovery histories; either skipped capture is rejected | Add separate terminal-capture workloads and actual serialized final-checksum corruption |
| A wide inventory makes pairwise path comparisons expensive | A bounded 40-second profile spends 35.58 seconds collapsing measurement roots | Check ancestor membership in a set, preserving the exact full report |
| A fallback expression can run even when its result is unused | The original measurement test walks all three roots despite two successful `du` results | Compute fallback sizes only for missing roots |

The full replay probes exit zero on both verified engine pins. Their receipts
retain the unchanged source's speculative-checksum and missing recovery-only
limitations. No source parity or browser transport claim follows from the
new Godot terminal boundary.

The original and optimized cache reports contain exactly the same 4,531 entries,
reasons and sizes (195,528,213 bytes). The optimized phases total about 8.36
seconds. A deterministic comparison-count regression protects complexity;
no machine-dependent timing threshold was added. No cache was deleted.

## Curation and pruning

The existing callback rules remain correct; the diagnostic omission required
production code and regression coverage rather than another overlapping skill.
The existing oracle-validation reference already distinguishes terminal cleanup
from the original failure and requires independent original history. Retained
those rules and their prior-session evidence.

Updated the existing workspace-hygiene command table with `--diagnostics`.
The owning cache guide records reproducible phase measurements and their limits.
No knowledge or skill was retired: none was disproved. No new skill was needed.

The first relocated online regression probe omitted `scripts/` from its import
path; corrected the instrument before interpreting its intended rejection.
Initial integration runs used the launcher's default 60-second shard deadline.
The Makefile requires 180 seconds; corrected the command and retained the
watchdog receipts. Neither mistake justified changing production expectations.

## Outcome

State: `findings-acted`. The source recovery-only, transport-refusal, full
upstream parity and release matrix requirements remain in their existing issues.
Candidate CI, feedback, merge and main-CI results are tracked separately from
these local observations.
