# Retrospective — 2026-11-27 coordinator silence oracle

## Work under review

Qualified one five-endpoint coordinator silence schedule on the Fortress v6
candidate and the two Godot pins for #550. The fixture drives each production
session over addressed queues and captures original history, controls, and
the barrier outcome.

## Findings

| Finding | Evidence |
| --- | --- |
| Coordinator cutoff and last delivered control are different clock events. | The router cut off 0 at 5.450 s. Endpoint 1 last consumed an addressed control from 0 at 5.440 s and emitted its first COMMIT at 6.440 s. |
| Replay can pass vacuously if it bypasses ingress, observes only report keys, or never verifies a live control on that route. | The first review found all three gaps in the candidate retry test. The revised test synchronizes the endpoints, sends accepted epoch-one INVENTORY through that route, and compares full reports, the grace clock, and the live attempt after replay. |
| A wire certificate and a peer-drop notification leave the applied cut ambiguous. | The revised observer reads each target's local receipt frame and connection state when each survivor's public event fires. |

## Actions taken

- Kept the shared schedule, boundary probe, and raw receipts together in the
  scoped oracle. The [command](../../docs/oracle-p2p.md#coordinator-silence-on-the-version-6-candidate)
  uses a distinct output directory for each engine.
- Recorded the replay and applied-cut checks in [transport tooling](../knowledge/transport-tooling.md).

## Prune ledger

The older four-endpoint participant-loss test remains useful for that policy.
The archive qualification guide now links the five-endpoint silence witness
for the pending-barrier availability difference.

## Outcome

- State: `findings-acted`
- Follow-up: use the archive-bound receipt to finish [#546](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/546).
