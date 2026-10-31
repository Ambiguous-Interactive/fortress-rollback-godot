# Retrospective: replay imports and spectator buffer feedback

## Work under review

Session 131 adds native replay file drops and spectator receive-capacity feedback.
New UI capabilities and a corrected test fixture trigger this retrospective.
The driver ownership audit and asymmetric recording inspection found no new demonstrated defect.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Detached scene callbacks do not establish window lifecycle wiring. | The first manual `get_window()` fixture returned null; deferred real-tree probes pass eight attachment/removal/reentry assertions on both engine pins. | Keep bounded-import handler tests in the existing suite; use actual entered-tree signal evidence for wiring. |
| Punctuation keys beside colons can be misread in rendered help. | The source-rendered `,:` and `.:` image was read as other keys; the explicit-key label control fails before repair. | Spell out Comma and Period in the scene, regenerate its image, and extend the existing user-copy guidance. |
| A paused input buffer can be full while viewing is still recoverable. | Actual local publication fills 128 rows without terminating; C frees capacity without advancing the host. | Show recovery controls before history failure; suppress them for closed or stopped playback. |

The existing [UI evidence guidance](../skills/testing/references/browser-integration.md)
and previous [timeline retrospective](2026-10-31-playback-and-setup.md) already cover live-tree evidence.
No new overlapping skill is needed; the existing user-copy skill now covers punctuation key labels.
The invalid fixture is not production red evidence.
Baseline capability tests fail only for the absent handler, capacity fields and warning.

## Verification and limits

Focused suites pass 34 unique cases in repeated processes.
A fresh adversarial reviewer found no actionable defect and verified native signal lifecycle on both pins.
The rendered full-buffer example was inspected for readable controls and complete boards.
The recovery test also requires a real refused publication, exact retained bytes and successful delivery after catch-up.
Native signal delivery was exercised programmatically; an operating-system drag was not.
The new capacity observations preserve receive-window bounds and do not establish transport readiness.
Machine-local progress receipts retain full test and delivery results.

## Prune ledger

- Existing ownership, GUI routing and source-freeze guidance remains valid.
- No stale rule or duplicated knowledge entry was identified.
- No whole-tree copy or new build tree was created; small probes use the owned scratch directory.

## Outcome

Retro: findings-acted
