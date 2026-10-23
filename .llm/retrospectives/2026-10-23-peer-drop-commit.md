# Retrospective: Peer-drop commit acknowledgement

## Work under review

Repair the coordinated-drop control handshake after the departed slot freezes.
The trigger is a production reliability incident under #181, discovered while
advancing the gameplay recovery work in #166.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Gameplay completion can suppress required protocol completion. | `peer_drop_barrier.gd:received` returned on the frozen target before commit or ACK dispatch. The clean packet regression delivered an ACK yet observed three COMMIT packets. | Allow matching committed control and test quiescence before timeout. |
| Checking only a sequence loses the rest of an operation's identity. | `test_peer_drop_identity.gd` accepts wrong coordinator, era and target reports on the original code; a foreign abort cancels and foreign backfill terminates the match. | Check the locally derived full identity before every phase; remove the redundant operation-order registry. |
| A packet-drain clock can differ from publication time. | The first delayed-READY fixture captured COMMIT one millisecond after READY delivery; the corrected same-time drain proves the timestamp repair with an isolated one-line removal. | Measure the real publication boundary before asserting a retry deadline; retain the exact boundary regression. |

## Distillation and pruning

Extended the existing [networking skill](../skills/networking-transport/SKILL.md)
with terminal-target versus committed-control guidance. No new skill or fact
store is needed. Removed the runtime operation-order registry: this fixed-roster
tier derives exactly one valid operation from each target's eras. The complete
pinned participant/journal semantics remain explicitly tracked in #166.

## Verification

The new packet tests fail on original production and pass after repair.
Both pinned engines run the existing and new drop suites. Session-local logs
are under `.cache/tests/session063-*` and the delivery gates are recorded in #181.
Source widths, harness regeneration, lint and self-tests run before delivery.

## Outcome

State: `findings-acted`. Remaining participant-certificate, retransmission-journal
and exported live-witness acceptance stays under #166; no full parity claim.
