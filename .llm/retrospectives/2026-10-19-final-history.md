# Retrospective: 2026-10-19 final history

## Work Under Review

- Scope: shared session/driver/peer recovery without a forward frame; exact replay tails and playable spectator endings.
- Trigger: new capability and adversarial findings.
- Evidence: `test_driver_recovery.gd`, `test_peer_recovery.gd`, `test_spectator_demo.gd`; native/browser and differential receipts recorded in the session issue updates.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Successful recovery must preserve staged local input even when its result is OK. | `test_driver_recovery.gd:staged_sample` and `Session.complete_request` | Clear samples only after actual forward advancement; update rollback guidance. |
| A previously saved current boundary becomes stale when preceding inputs are corrected. | The boundary-checksum regression published 17628 while corrected state was 24188 before repair. | Save the corrected current boundary; add the regression and owning guidance. |
| A stopped host still owes liveness until its final rows and END are accepted. | Pausing 620 ticks after stopping a 130-frame host expired the viewer at the original ten-second deadline. | Keep independent heartbeats until publisher completion; cover resume through the exact final state. |
| Final receipt convergence can stall below prediction-window exhaustion, and a locally confirmed sender can still owe gossip to a lagging recipient. | `test_peer_recovery.gd:idle_confirmation` failed with zero carriers before the explicit-recovery change. | Keep bounded historical status carriers eligible during explicit recovery, including after asymmetric packet loss. |

## Prune Ledger

- Fixed the existing rollback and transport guidance in place; no duplicate knowledge entry or new skill.
- Replaced the spectator guide screenshot with the actual completed final state.
- Existing spectator authentication, upstream semantic acceptance and browser release limitations remain valid and tracked.
- Verify-on-touch: source widths, generated harness indexes/stubs, harness lint and self-tests.

## Outcome

- State: `findings-acted`.
- Follow-ups: full driver/replay/spectator task acceptance remains in issues #40, #45 and #47; broader upstream P2P acceptance remains in #59; authenticated spectator relay startup remains in #131.
