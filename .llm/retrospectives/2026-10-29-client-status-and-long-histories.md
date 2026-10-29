# Retrospective: client status and long histories

## Work under review

Session 111 advances #40, #45 and #47/#131: scalar applied input status,
malformed view safety, longer actual-source recording, and corrected spectator
history under scripted SDK pressure. Trigger: runtime debugging and expanded
verification across queue reuse.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Ordinary engine-created views hide malformed public constructor metadata. | `FrameInputs.read()` indexed an empty status array; `test_frame_inputs.gd::malformed_statuses` reproduces the error before repair. | Shared shape validation protects owned, reusable and scalar reads; GDScript guidance now includes constructor backing arrays. |
| Extending an unchanged cadence crosses periodic protocol boundaries. | Actual Rust long recordings deliver ten messages at rounds 63/123/183/243; the original eight-message expectation fails at round 63. | Preserve upstream interval-60 checksum traffic, derive its exact schedule and reject incorrect delivery counts. |
| Byte-only game checks cannot qualify status-sensitive adapter composition. | An executed spectator mutation preserves input bytes but changes disconnected status to confirmed; independent game and export checks fail. | Add one composed status-sensitive SDK-double case, including retained pressure and physical source-ring eviction. |

## Curation and pruning

Searched existing view, recording and oracle guidance before updating it.
Extended the existing GDScript view-validation rule and oracle inventory guidance;
no new skill or duplicate knowledge entry was needed. Existing networking guidance
already covers recorded row shapes and remains valid. Source and browser acceptance
limits remain explicit; no old source discrepancy or unqualified live gate was removed.

## Verification

Focused frame-input tests pass on both engine pins. Independent driver review is clean.
The initial replay review reproduced the periodic-message failure, and the implementation
retains that traffic with exact expected counts. Final source-bound, full-suite, review
and delivery gates remain pending while this artifact is written. The ignored
`progress/session-111-client-boundaries.md` records their commands, live handles
and results; issue updates follow verified delivery.

## Outcome

State: findings-acted. Broader #40/#45/#47/#131 acceptance remains open.
