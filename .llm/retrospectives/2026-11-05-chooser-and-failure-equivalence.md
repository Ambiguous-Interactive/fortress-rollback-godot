# Retrospective: replay chooser and callback failure equivalence

## Work Under Review

Session 157 advances driver #40, replay #45 and spectator #47 acceptance.
Replay inspection pauses before opening a file chooser. Driver and spectator
checks compare callback failures with independently dispatched expert requests.
The trigger is an inspection capability and acceptance-coverage investigation.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A modal chooser can leave playback running without application focus loss. | `examples/online/replay_scene.gd::_open`; the expanded `scripts/reference/replay_navigation_probe.gd` fails the original chooser pause/cancel assertions. | Reuse the controller's inspection pause before either platform chooser; extend existing style guidance. |
| Successful callback equivalence does not establish failure equivalence. | `tests/unit/test_driver_callback_results.gd::_expert_failure_parity` covers SAVE/LOAD/ADVANCE; `tests/unit/test_spectator_session.gd::_expert_failures` covers SAVE/ADVANCE after ring reuse. | Extend existing registered suites and their browser inventory; retain explicit canonical, lifecycle and prefix assertions. |
| Shared-source qualification must follow all edits, including documentation and commits. | The development driver 4.3 receipt rejects concurrent edits as `source_changed` while its child cases succeed. | Preserve the rejected receipt and qualify the final frozen candidate; existing infrastructure guidance already covers this. |

## Prune Ledger

Searched existing style, testing and knowledge guidance before extending the
inspection-pause rule. No duplicate skill or new modal abstraction was added.
Existing source-freeze, independent comparison and mutation-control rules remain
authoritative. No stored claim was proved obsolete by this work.
Generated index/stubs and harness verification are recorded in the session log.

## Outcome

Retro: findings-acted.
Original driver equivalence, replay source/platform parity and live spectator
acceptance remain in their existing issues. Native chooser evidence does not
qualify browser file-picker interaction.
