# Retrospective: playable spectator replay files

## Work under review

The session connects saved spectator recordings to the bundled replay viewer,
adds bounded catch-up controls, and exercises encoded asymmetric-recording
corruption through actual decoding and playback. These advance #45, #47 and #256.
New capabilities and an evidence-validator repair require this retrospective.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A successful export is insufficient when the advertised viewer refuses its game identity. | The new `test_spectator_replay_viewer.gd` imports actual `Demo.replay_bytes()` output and compares completed offline playback with the original canonical game. The original viewer refuses that file. | Identify new exports explicitly and select the matching initial state, callbacks, input names and snapshot width. Extend the existing producer/import guidance. |
| Comparing two mutated byte strings does not establish that either represents the original file. | Fresh review accepted common header/metadata changes through the first `replay_corruption.validate()` implementation. The header-forgery table fails before repair. | Independently construct the complete original file, including observed engine metadata, before accepting the single allowed mutation. Extend the existing oracle-validation rule. |
| Pausing the render fixture can suppress the normal redraw after deferred layout. | A frozen-physics capture initially overlapped the panel; normal physics rendered the unchanged board correctly. `progress/session-120-layout-control.png` and the final documented screenshot agree. | Remove unsupported product layout changes and synthetic regression claims. Render after layout and request redraw when the fixture deliberately disables physics. |
| The driver's existing lifecycle tests already cover the suspected gaps. | The #40 audit found no reproducible contract violation in configuration, callback returns, recovery, staged samples or shared notifications. | Leave production code unchanged for that audit and spend implementation effort on a demonstrated user workflow gap. |

## Prune ledger

Updated the existing [infrastructure evidence](../skills/testing/references/infrastructure.md)
producer/import paragraph and [oracle validation](../skills/testing/references/oracle-validation.md)
mutation paragraph. No new skill or duplicate knowledge home was created.
The rendering rule already requires a live scene after layout in infrastructure
guidance; no duplicate rule is needed. Removed the proposed layout fix and its
release-note claim after the control disproved the production-bug hypothesis.

Replaced the spectator guide's obsolete statement that the bundled viewer refuses
its files. Older unnamed exports remain refused deliberately: their game cannot be
safely inferred. Current game identity is explicit without changing the portable format.

## Verification

Focused new capabilities pass twice on both engine pins. Fresh catch-up and replay
import reviews are clean. The encoded-control review finding was reproduced by a
separate evaluator, repaired, and re-reviewed without remaining findings.
Both complete pinned-source replay gates pass with unchanged source/tool inventories;
actual corruptions stop at canonical boundary 129 through the production player.
Native, exported ownership, harness and final delivery gates are recorded in the
session log and linked issue updates. The source and platform scope remains the
original issues' scope; this work makes no complete-parity or browser-release claim.

## Outcome

Retro: findings-acted
