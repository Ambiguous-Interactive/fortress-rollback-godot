# Retrospective: preserve gameplay history and playback evidence

## Work under review

Three scoped repairs advance issues #188, #47 and #45: final-survivor history,
spectator event ownership and explicit replay final-state coverage.
The debugging incidents and new public replay query require this retrospective.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A final-survivor shortcut skipped retained-history protection used by the multi-survivor barrier. | `peer_drop_barrier.gd` selected confirmation without target receipts; `last_survivor_receipts` failed its cut, canonical-state and replay assertions. | Reuse the captured inventory, raise the cut and validate every target before freezing. |
| Spectator event drains used the callback guard but omitted completion notifications. | `test_spectator_policy.gd` observed handler drains `[1, 0]`, consuming the terminal event before later observers. | Use the shared guard and test cancellation across two handlers. |
| A checksum count cannot identify whether the final game state was checked. | Historical files have pre-input checksums; terminal coverage tests distinguish those files from matched final-state evidence. | Expose the final-boundary query and label viewer completion precisely. |

## Durable guidance

Updated the existing [rollback skill](../skills/rollback-fundamentals/SKILL.md)
with the final-survivor inventory invariant and destructive event-drain fencing.
The existing final-state checksum guidance already covers replay evidence;
API and viewer behavior belong in integration documentation.
Regression evidence and command receipts are in machine-local
[session 085](../../progress/session-085-gameplay-boundaries.md).

## Prune ledger

Considered existing event, drop and replay guidance. Extended the owning skill
instead of creating another knowledge topic or duplicating replay invariants.
No existing entry was proved obsolete. Generated discovery files remain generated.
The workspace report identifies 1.04 GB of old reclaimable output; this session
uses bounded reports and existing revision-keyed caches.

## Outcome

State: `findings-acted`.
The broad upstream parity, live spectator routing and platform release gates
remain tracked in their existing issues; these repairs do not establish them.
