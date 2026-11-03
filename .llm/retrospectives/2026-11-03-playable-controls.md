# Retrospective: 2026-11-03 playable controls

## Work under review

Session 147 advances effects, replay and local spectator controls under issues
40, 45 and 47. New capability and a reproduced restart defect trigger this review.
Evidence includes the deterministic scene cases, deferred navigation probe,
rendered screenshots and fresh adversarial review.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A refused controller reset cleared scene effects | `examples/integration/integration.gd::_restart`; `test_integration_demo.gd::_restart_presentation` fails before repair | Reset presentation only after successful controller replacement; add this rule to the existing GDScript skill |
| Preflight acceptance does not establish seek success | Fresh review reproduces `checkpoint_checksum` rejection through the frame field | Preserve seek's returned acceptance; retain editing focus on refusal; exercise actual GUI submission in the existing deferred probe |
| Control layout must reserve actual game geometry | Rendered effects scene initially placed buttons across the board edge | Derive board placement and scaling from controls; inspect the rendered result |
| A focusless selector omitted keyboard access | Automatic review; host-delay case fails before number-key handling | Add 1/2/3 through the shared handler, actual routed-key checks and the existing browser-integration test guidance |
| Logical number keys hid AZERTY shortcuts behind the modifier guard | Physical-symbol events fail before repair in all three numeric-key examples | Use physical number-row codes, preserve key-only synthetic input, and test actual layout events |
| GUI fixtures need settled layout before text replacement | Deferred SpinBox updates replaced injected text with its prior value | Await completed layout before typing; retain paired healthy and damaged-restore cases |

The metadata-control hypothesis was discarded after inspecting the replay
format's existing printable-ASCII validation. No redundant escaping was added.
The native popup witness initially injected into the wrong coordinate domain;
real screen coordinates include the embedding root window position. The final
OS pointer witness selects the host delay and checks the resulting gameplay.

## Prune ledger

Existing GDScript guidance owns scene lifetime and ownership rules; extend it
rather than create another skill. No prior rule was invalidated. Existing
source inventory and native/Web tests remain authoritative; no test gate was
removed. Current source-width and harness checks validate the guidance edit.

## Outcome

State: findings-acted. Native/Web qualification, candidate CI, final feedback
and merge/main verification were pending when this artifact was written.
The local session log and linked issue delivery notes maintain current evidence.
Original broad release, parity and spectator transport acceptance remains open.
