# Retrospective: online service ownership

## Work under review

Session 123 fixes the online room and match controllers under issues #38, #40
and #45, plus the discovered callback Leave defect #266. The incident concerned reentrant service, setup and replay finishing
while callbacks, notifications or manual requests owned the match.

## Evidence

The unchanged implementation fails `test_online_ownership.gd` with no engine
errors. Nested service commits timestamp 1000000000 instead of 333340 and
reports `Protocol stopped (9)`. A manual writer expires during that rejected
service. A nested lobby tick also commits the future timestamp and polls the
SDK and mesh twice. Replay finishing changes its flag while work remains owned.

The isolated baseline receipt is machine-local
`progress/session-123-baseline-controls.json`. Paired startup and ordinary
service controls establish healthy matches before the reentrant operations.
The repaired five-case suite passes in fresh processes; full native and CI
results belong in the session log and linked issues.

Cancellation review then reproduced SDK Leave freeing an actively emitting Node,
which aborts cleanup with a locked-object error. Match detach during SAVE also
allowed frame10 to advance to11 and later reported a transport failure. The
cancellation suite records the paired idle control and exact failures. A further
startup witness catches stale continuation after adapter status, peer getters,
transport polling and setup returns. The initial fixture used Node's reserved
`owner` property; its parse error was corrected before interpreting its red run.

The first complete native chain was deliberately stopped before source changes;
its partial receipt is unqualified. Complete native and CI gates still require
final candidate runs. The final focused receipts `session-123-online-v3-43.json`
and `session-123-online-v3-472.json` pass all39 online cases in each fresh run,
with zero engine errors. Harness validation passes161 self-tests.

The initial pushed head also fails `manual_leave` with zero engine errors:
retained work blocks fresh-room validation and failed-state SDK close polling,
and leaves the writer active. `session-123-feedback-manual-red.json` records the
failure; the final focused runs prove the corrected public behavior.

## Findings and actions

| Finding | Action | Evidence |
| --- | --- | --- |
| Inner BUSY cannot undo outer service side effects | Guard match and lobby controls before clock, token or SDK work | `examples/online/match.gd`, `examples/online/lobby.gd` |
| SDK callbacks can reenter when the peer is idle | Keep a controller service guard across the complete accepted operation | `test_online_ownership.gd`: service and lobby controls |
| A plausible recording-cap failure was not a defect | Reject the hypothesis after real full-cap viewing and clean-end probes | Independent spectator review; both probes exited zero |
| Callback Leave frees active SDK owners and leaves game work alive | Retire logical ownership first, defer physical Node release and fence every startup continuation | `test_online_cancellation.gd`; issue #266 |
| The native launcher does not accept a project-path option | Run the scratch copy's launcher from its working directory | Initial argument rejection, then baseline receipt |

## Curation and pruning

The existing [rollback fundamentals](../skills/rollback-fundamentals/SKILL.md)
already requires composed controls to validate ownership before clocks or
staging. Its callback and notification rules remain correct. Applied that rule
at the uncovered online controllers instead of adding duplicate guidance.
Updated the existing callback-lifetime paragraph in
[networking transport](../skills/networking-transport/SKILL.md) with the concrete
logical Leave, deferred physical release and startup-continuation checks.
The scratch launcher correction needs no new rule: the existing infrastructure
reference already requires checking actual command capabilities.

No guidance was retired: none was contradicted. The callback-lifetime paragraph
was expanded at its existing home; no new skill or knowledge file was needed. Scratch creation used the repository helper and excluded caches,
Git history, progress and engine imports. The broader browser and parity gates
remain open in their original issues; a clean spectator review claims no new
feature or acceptance milestone.

## Outcome

State: `findings-acted`. Follow-up implementation scope remains in #38, #40,
#45 and #47. Issue #266 owns callback Leave delivery; this repair changes no simulation or portable file format.
