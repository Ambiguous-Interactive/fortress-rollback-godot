# Retrospective: 2026-10-19 client lifetimes

## Work Under Review

Driver callback view validation, spectator lifetime fencing and replay backward stepping
advance issues #40, #47 and #45. Trigger: production bug investigations and a new UI action.
Evidence: deterministic original-code failures, matched valid controls, both engine pins,
fresh adversarial reviews and source-bound native/Chromium records. Delivery evidence
is recorded in the session PR and issue comments; machine-local logs live in progress/.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Named script view metadata distinguishes reader/writer misuse on current Godot; old guidance treated all script annotations as erased. | `addons/fortress_rollback/core/driver.gd`, `_accepts_view_class`; `tests/unit/test_driver_script_view_types.gd` exercises actual valid dispatch and rejected replacement. | Correct the existing GDScript callback guidance; retain the erased-type limitation. |
| A public playback session can replace its lifetime while its stream retains old authority. | `tests/unit/test_spectator_stream.gd`, `viewer_lifetime`: original rows reached a new viewer and old elapsed expiry terminated it. | Extend the existing transport lifetime rule to delivery and timeout ownership. |
| A backward-step UI action can reuse bounded, checksum-validated navigation without new replay semantics. | `tests/unit/test_replay_speed.gd`, `backward_step` and `scene_backward_step`: canonical states, failed-prefix replay, cancel and button states. | Keep the existing navigation implementation and test real scene actions. |

## Prune Ledger

Updated the canonical callback paragraph rather than adding a competing rule.
The metadata-erasure limitation remains valid and is narrowed to erased annotations.
Extended the existing transport lifetime paragraph; no new overlapping skill or knowledge file.
Prior retrospective evidence remains historical and was not rewritten.
No obsolete source, duplicated procedure or unsupported platform claim was introduced.

## Verification

`make llm-index`, `make lint-llm`, `make test-llm` and `make lint-source` validate
these edits. Full delivery gates must pass before the session is called complete.

## Outcome

State: `findings-acted`.
Remaining expert replay, allocation/parity and authenticated spectator acceptance
stay open in #40, #45, #47 and #131. No new deferred defect was identified.
