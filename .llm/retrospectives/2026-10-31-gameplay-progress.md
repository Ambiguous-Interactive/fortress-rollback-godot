# Retrospective: 2026-10-31 gameplay progress

## Work under review

Scope: online and local peer delay-action lifetimes, asymmetric recording final-state evidence,
and long three-player correction history. Trigger: debugging and new oracle coverage.

## Evidence and findings

| Finding | Evidence | Disposition |
| --- | --- | --- |
| Retained observations outlive actions and can overwrite recovery instructions. | New `delay_actions` in `tests/unit/test_online_example.gd` fails on main after actual Leave and protocol failure; live control succeeds. | Share scene readiness between prompts and handlers. Existing user-copy guidance already requires this; no duplicate rule added. |
| Separate pressure and terminal tests leave their combined behavior unqualified. | `scripts/oracle/replay_pressure.py` previously exported version 5 after stalls; terminal gate used the faster asymmetric cadence. | Combine pressure with terminal capture, preserving both original gates and independent missing-capture/corrupt-checksum controls. |
| An issue body can describe work superseded by later implementation. | Existing asymmetric helpers and `docs/oracle-replay.md` already cover the initial #256 schedule. | Inspect current sources and issue discussion before selecting the next acceptance slice. Existing ship-session instructions already require current-state inspection. |

| Parallel oracle helpers share a wider receipt fingerprint than their selected workload. | Full replay launchers refused changed-source receipts while the P2P helper was still changing. | Add explicit shared-directory freeze coordination to testing infrastructure guidance; definitive runs repeat after the freeze. |

| The same stale-action class also exists in the local peer scene. | `scene_delay_actions` rejects starting, closed and reset prompts on the initial code; public close also leaves the other delay key active. | Complete the sweep in the same session PR, before merge. Existing GOAL guidance already requires this; no duplicate instruction added. |

| Directly assigning a replacement cannot qualify production room replacement. | CodeRabbit finding on `test_online_example.gd`; removing the real lobby replacement now produces six exact replacement/state failures. | Drive Create and Join with SDK resource doubles, restore cache mappings, and release SDK Nodes. Existing testing boundary guidance remains authoritative. |

## Prune ledger

Considered user-copy and testing guidance. Their existing readiness, actual decoder,
negative-control and source-provenance rules remain applicable. The existing fixture-freeze guidance was extended at its source. No contradictory
or duplicate instruction needed retirement. Broader qualification gaps remain in
the linked open issues; scoped oracle results do not replace release acceptance.

## Outcome

State: `findings-acted`. Shared source-freeze guidance was made explicit; product and evidence defects were
addressed in their owning code and tests. Session receipts and delivery evidence
remain in machine-local `progress/session-126-gameplay-progress.md` and linked issues.
