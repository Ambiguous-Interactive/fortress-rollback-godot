# Retrospective: expert replay and client inspection

## Work under review

Expert replay requests share callback playback's ordered save/advance implementation.
The spectator example adds paused frame inspection; queue insertion uses one native
copy with immutable private sharing. New public APIs and a review-discovered
termination defect trigger this retrospective.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Adding termination to an existing callback owner requires auditing optional callback paths too | `test_replay_expert.gd`, `paused_termination`: the original implementation returned success after terminated validation/restoration, increased coverage and invoked a later save | Extend the existing rollback callback guard rule to paused validation and checkpoint restoration |
| A native bulk copy can outperform a per-byte loop while preserving public ownership | `docs/experiments/input-queue-performance.md`: both pinned engines, 2/4/8 queues, widths 1/8/32/256, seven samples and matching control checksums | Retain the reproduction script, source hashes and narrow-input noise; make no allocation or whole-game claim |
| Declared browser inventories catch incomplete integration during concurrent work | `test_ownership_probes.py` rejected the three new spectator cases and missing scene dependency before integration | Preserve the existing inventory guard and include all new suites/dependencies; no new harness abstraction needed |

Fresh-context spectator and queue reviews completed with no actionable findings.
Fresh-context replay review independently reproduced the termination defect.
A separate repair agent reproduced the failure, repaired all callback paths and
added terminal-result precedence tests. Both engine pins pass all eight replay
suites; a new fresh-context review of the repaired candidate is clean.

## Actions and pruning

Updated the existing callback paragraph in
[rollback fundamentals](../skills/rollback-fundamentals/SKILL.md), rather than
creating another skill or duplicating the networking callback rule.
Removed the obsolete no-expert-interface claim from `docs/oracle-replay.md`.
Preserved the explicit lack of independent expert/upstream differential coverage.
No older ownership guidance was removed: the new sharing is private and immutable;
public submission and result boundaries still copy.

Verification uses both pinned native engines, deterministic and differential
corpora, the source-bound native/Chromium ownership witness, source/harness
linters and fresh adversarial review after repair. Session progress records
exact commands and terminal receipts when each pending gate completes;
CI remains the final source-bound gate.

## Outcome

State: findings-acted.

Broad profiling, authenticated spectator networking and replay release acceptance
remain in their existing issues. No release or full-parity claim follows from
these scoped improvements.
