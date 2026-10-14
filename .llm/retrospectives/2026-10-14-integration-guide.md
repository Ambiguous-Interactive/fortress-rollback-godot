# Retrospective: 2026-10-14 integration guide

## Work under review

Scope: user-facing integration guide, minimal executable integration example and
confirmation-gated one-time effects (#41). Trigger: new user-facing capability and
one vacuous negative control. Evidence: [session log](../../progress/session-022-integration-guide.md).

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| No example had input-driven effects, so no test could expose a predicted effect that rollback removes. | Coverage gap | Offline/peer/online pulses derive from snapshotted randomness only |
| `confirmed_frame` rises on delivery before the next step corrects state, so confirmation alone can play a mispredicted shot. | Technique | Fresh review reproduced it; removing the `pending_rollback_frame` clamp fails the burst row |
| An evidence validator bounded confirmation by submitted samples, ignoring input delay; an early intended DESYNC exposed it in CI. | Technique | Run `38512087955`; failed peer frame 31, confirmed 32, 32 samples |
| A negative control passed vacuously because the test's keys depended on frame, not tick, so resampling produced identical bytes. | Technique | `.cache/tests/session-022-resample-red.log` after the test changed keys on stalled ticks |

## Actions taken

| Action | Canonical home | Verification |
| --- | --- | --- |
| Document effects gated by confirmation and pending rollback. | [Rollback fundamentals](../skills/rollback-fundamentals/SKILL.md), [integration guide](../../docs/integration.md) | Ungated, unclamped and off-by-one ledgers all fail |
| Bound confirmation by samples plus input delay in the online validator. | `scripts/reference/online_example_probe.py` and its tests | Old bound fails the CI-shaped fixture; 72 reference tests pass |
| Vary the input the mutation depends on before trusting a control. | Existing testing guidance on meaningful red controls | Resample mutation now fails with `INPUT_ALREADY_SUBMITTED` |

## Prune ledger

The offline guide's "future online play" effects caveat remains accurate; it now
has a tested counterpart in the integration guide. No skill was duplicated. The
testing skill is at 299 lines, so no new line was added there.

## Outcome

State: `findings-acted`.
