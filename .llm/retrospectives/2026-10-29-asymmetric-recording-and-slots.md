# Retrospective: asymmetric recordings and spectator slots

## Work under review

Session scope: client readiness allocation, asymmetric remote recording and
per-slot disconnected spectator source comparison. Trigger: new verification
capabilities and measured production optimization.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Zero-filled observations can conceal skipped successful reads. | `scripts/benchmark_session_hot_path.gd` measures retained readiness where OK equals zero; the skipped-read control must reject the untouched slot. | Initialize observations with an invalid sentinel; extend the testing measurement rule. |
| An asymmetric workload must expose different executed histories. | `scripts/oracle/replay_asymmetric.py` checks distinct correction schedules, exact service and delivery inventories, original canonical prefixes and final recovery. | Keep symmetric controls and compare both endpoints independently instead of relabeling a shared cadence. |
| Disconnected status belongs to a specific player slot. | `scripts/oracle/spectator_status.py` executes a shifted-status mutant with unchanged input bytes and status sums. | Expand the actual-source witness to every reserved slot and compare ordered statuses and canonical boundaries. |
| Source export policy can differ from a product recovery API. | `scripts/oracle/rust/src/bin/replay/remote.rs` observes source rejection without a new local sample; Godot performs recovery without advancing. | Preserve the source observation and speculative-checksum discrepancy; do not claim complete source recovery parity. |
| A live tool session is not a portable ownership handoff. | Parent and child could no longer poll the first child-owned replay launchers; process inspection confirmed exit without success receipts. | Keep the owning verification turn active through terminal completion; document completed-receipt handoff in infrastructure guidance. |

## Prune ledger

Existing oracle guidance already requires original histories, exact inventories,
executed controls and explicit projections. Keep those rules in their current
home; no duplicate skill or new operational knowledge entry is needed.
The prior last-slot evidence remains a subset of the expanded witness.
Historical source discrepancy evidence remains valid and is not retired.

## Verification

Focused engine, source and mutation evidence is recorded in the ignored session
logs. Final source-bound probes, full suites, fresh adversarial reviews and CI
must pass before delivery. Harness regeneration and integrity checks accompany
this change; no generated files are hand-edited.

## Outcome

Retro: findings-acted

Broader recording, live spectator routing, reactivation and browser release gates
remain in their original issues. This session does not establish full parity.
