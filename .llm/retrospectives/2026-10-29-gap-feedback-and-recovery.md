# Retrospective: gap feedback and recovery

## Work Under Review

Session 118 advances spectator feedback, asymmetric recording under prediction
stalls and coordinated-drop recovery after a lost inventory answer. The trigger
is a public observation capability and expanded independent acceptance evidence.
Evidence lives in the changed spectator tests, `replay_pressure.py` and
`drop_history_inventory_controls.py`; execution receipts remain in ignored `progress/`.

## Findings and Actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A contiguous buffering count cannot explain accepted rows beyond a gap. | Spectator observation and exact scene-label controls fail against the original source. | Add owned pending/missing observations and document their distinct meaning. |
| Service turns diverge from simulation frames after prediction stalls. | The pressure witness exercises retained samples, stalled SAVE requests and resumed canonical history. | Keep both identities explicit; existing oracle guidance already requires attempted and completed work separately. |
| A retry with equal bytes does not prove the first answer was lost. | The inventory witness reconciles source/Godot emissions minus the discarded packet with actual receipts. | Retain exact omission/retry controls; existing packet-loss guidance already owns this method. |
| Retry existence and emission order do not prove consumption before a decision. | Cold reviews exposed missing source receipt chronology, Godot routing-time proxies and accepted duplicate order values. | Observe actual publication/receive boundaries in both runtimes, reject late-consumption and duplicate-order mutants, and extend oracle-validation guidance. |
| A stronger structural guard can hide a semantic test target. | Automatic review found the ACK-before-COMMIT control reached duplicate-order rejection. | Keep the duplicate-order case, restore a unique-order early ACK and extend the existing exact-diagnostic guidance. |

## Prune Ledger

The existing oracle-validation guidance covers attempted service, original samples,
emission/receipt attribution and exact diagnostics. The missing prerequisite-order instruction extends that existing procedure; no
new skill is needed. The browser-integration guidance still requires actual visible
feedback; the rendered gap scene and exact label tests follow it. No canonical
claim was retired. Source/tool pins and broader source/network release gates remain unchanged.

## Outcome

State: findings-acted. Broader acceptance remains in #47/#131, #256/#253 and
#188/#166. The new UI explains gaps; it does not request retransmission or prove liveness.
