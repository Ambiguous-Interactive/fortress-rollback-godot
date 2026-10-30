# Retrospective: online service ownership

## Work under review

Session 123 fixes the online room and match controllers under issues #38, #40
and #45. The incident concerned reentrant service, setup and replay finishing
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

## Findings and actions

| Finding | Action | Evidence |
| --- | --- | --- |
| Inner BUSY cannot undo outer service side effects | Guard match and lobby controls before clock, token or SDK work | `examples/online/match.gd`, `examples/online/lobby.gd` |
| SDK callbacks can reenter when the peer is idle | Keep a controller service guard across the complete accepted operation | `test_online_ownership.gd`: service and lobby controls |
| A plausible recording-cap failure was not a defect | Reject the hypothesis after real full-cap viewing and clean-end probes | Independent spectator review; both probes exited zero |
| The native launcher does not accept a project-path option | Run the scratch copy's launcher from its working directory | Initial argument rejection, then baseline receipt |

## Curation and pruning

The existing [rollback fundamentals](../skills/rollback-fundamentals/SKILL.md)
already requires composed controls to validate ownership before clocks or
staging. Its callback and notification rules remain correct. Applied that rule
at the uncovered online controllers instead of adding duplicate guidance.
The scratch launcher correction needs no new rule: the existing infrastructure
reference already requires checking actual command capabilities.

No guidance was retired: none was contradicted. No new skill or knowledge file
was needed. Scratch creation used the repository helper and excluded caches,
Git history, progress and engine imports. The broader browser and parity gates
remain open in their original issues; a clean spectator review claims no new
feature or acceptance milestone.

## Outcome

State: `findings-acted`. Follow-up implementation scope remains in #38, #40,
#45 and #47; this repair changes no simulation or portable file format.
