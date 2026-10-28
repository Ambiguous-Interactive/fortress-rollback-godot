# Retrospective: 2026-10-28 gameplay recovery boundaries

## Work under review

Session 104 advances peer-drop recovery (#188), real spectator lifecycle
acceptance (#131), and recording applicability (#45). The trigger is a production
bug, new acceptance coverage and fresh-review corrections.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A negotiation deadline cannot retire irreversible commit recovery. | `peer_drop_barrier.gd` suppressed committed retries at the original deadline; `test_peer_drop_late_ack.gd` fails at equality and one microsecond later before repair. | Correct the transport skill's deadline guidance and lifecycle documentation. |
| Indefinite operation recovery needs per-recipient acknowledgement filtering. | Fresh review identified retries to an acknowledged survivor; the four-peer `late_ack_partial` case observes destinations `[1, 3]` instead of `[3]` before repair. | Stop COMMIT sends to acknowledged identities; retain exact retry and quiescence controls. |
| Equal canonical state does not prove complete callback observation. | `Game.load_state()` restored bytes without recording LOAD; `records_load_callbacks` rejects that omission while preserving the same canonical bytes. | Record LOAD and add explicit unexpected-request controls. |
| Completed gameplay differs from service attempts. | Actual pinned zero-window Rust execution needs empty attempts; Godot all-local execution advances immediately. | Require bounded attempt traces and completed ADVANCE counts independently. |

## Distillation and pruning

Updated the existing networking skill rather than creating overlapping guidance.
Replaced its before-timeout-only ACK instruction with deadline-crossing recovery
and post-ACK quiescence. Added observer completeness to the existing oracle
validation reference. No historical runtime evidence was retired.

Verification uses both pinned engines, actual source recording traces, physical
SDK/server departure cases, fresh adversarial reviews and the session CI gates.
Detailed commands and receipts live in machine-local `progress/` and linked issues.

## Outcome

State: `findings-acted`.
Remaining scope: exported spectator identity/lifetimes (#245), remote/drop
recording applicability (#45), and broader source/live drop acceptance (#188).
