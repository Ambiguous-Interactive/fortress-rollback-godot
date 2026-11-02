# Retrospective: playback controls and carried delivery

## Work under review

Carry forward PR #302's received replay files, wrapped donor recovery and native
source images. Add pointer host ending/restart to the local spectator and align
replay controls with held game work. Investigate remaining #188 no-donor history
acceptance without changing its physical/live scope.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Controller refusal can leave a misleading enabled button. | `examples/online/replay_scene.gd::_refresh` formerly omitted game ownership from navigation and file-selection readiness. | Share the held-work gate and test a real manual SAVE/ADVANCE batch. |
| Keyboard-only recovery leaves pointer users unable to restart viewing. | `examples/spectator/spectator.gd` formerly exposed host ending and restart only through E/R. | Bind pointer controls to the same handlers and verify retained old handles cannot resume. |
| A plausible synthetic history can be unreachable through the byte transport. | `peer_session.gd::_prepare_step` and `input_endpoint.gd` require complete agreed player lists in each input frame. | Discard the proposed complementary-slot peer fixture; retain the physical/live acceptance gap in #188. |

## Actions and evidence

The replay regression fails before repair at the intended enabled-control
assertions. The spectator regression fails before adding its missing controls.
Both focused inventories pass twice on both pinned Godot engines after repair.
Live spectator inspection verifies visible controls, pointer delivery and board
layout. Final candidate qualification and delivery evidence belong in the
machine-local session log and linked issues; earlier receipts keep their actual
executed revisions.

Existing [copy guidance](../skills/user-copy/SKILL.md) already requires product
actions to share readiness gates. Existing
[testing guidance](../skills/testing/SKILL.md) already requires observable
behavior and credible regressions. No additional rule or duplicate knowledge
entry is needed.

## Prune ledger and outcome

Considered existing guidance and the previous source-image retrospective; neither
is superseded. Removed the proposed unreachable-history tests before delivery.
The remaining exported spectator, physical no-donor and complete received-file
qualification requirements stay open in #245, #188 and #290.

Outcome: `findings-acted`.
