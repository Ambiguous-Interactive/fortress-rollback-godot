# Retrospective: 2026-10-19 client publication

## Work under review

Driver callback type validation, paused replay boundary validation, and bounded
confirmed spectator publication. Trigger: production debugging and a new API.
Evidence: session040 local progress log; deterministic original-code/mutation
failures, pinned engine receipts and fresh adversarial review.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Reflected builtin callback types can disprove call compatibility even when arity passes. Script annotations may be erased. | `driver.gd`, `accepts_callback_arguments`; original wrong-frame callback left both guards BUSY. | Refine GDScript guidance; preserve broad valid callbacks in regression controls. |
| A paused replay target must use the same snapshot failure contract as stepping. | `replay_viewer.gd`, `_finish_seek`; `test_replay_diagnostics.gd`, `boundary_validation`. | Route viewer checks through core; update browser testing guidance. |
| A refused confirmed row can outlive the host's physical input ring. | `spectator_publisher.gd`, `prepare_packet`; `test_spectator_publisher.gd`, `retained_publication`. | Own the prepared bytes and fence the host configuration before retry; extend transport guidance. |

## Prune ledger

Corrected the overly broad claim that method metadata cannot prove parameter
types: builtin incompatibility is detectable; script annotations remain limited.
Replaced viewer-specific validation and the demo's handwritten publication loop.
Existing replay format, authentication and full browser acceptance limits remain
accurate. No additional duplicate guidance was introduced.

## Verification

Run source widths, harness index/stub regeneration, harness lint and self-tests.
Both pinned native engines, exported Chromium exact inventories and fresh reviews
are recorded in the session progress log and delivery evidence.

## Outcome

State: findings-acted. Broader driver allocation/parity, replay semantics and live
spectator handshake/relay acceptance stay in existing issues #40, #45, #47 and #131.

Review also expanded the frozen-host guard from preparation to acknowledgement
and keepalive generation. Every public publication path must check the same
lifetime/boundary invariant. A brief shared-tree mutation preceded the source
freeze; later reviews rechecked final hashes and all source-bound gates restarted.
Existing testing guidance already requires isolated, frozen execution evidence;
no duplicate procedure was added.
