# Retrospective: 2026-10-12 physical channel loss

## Work under review

Session 017 carries the unmerged overlap repair, adds real channel-loss recovery
evidence and an optional guarded SDK multiplayer peer factory, and repairs slow
witness service cadence. Trigger: new capability, incident and review corrections.
Evidence: [session log](../../progress/session-017-physical-fallback.md), native
red/green receipts, independent reviews, and the source-bound 16-run browser receipt.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Sender packet bytes do not uniquely identify the transport recipient. | First fresh review attacks payload-selected closure; duplicate-payload instrumentation control now passes. | Select through frozen UUID membership; add the rule to the transport skill. |
| Source close events cannot precede their own initiation. | A frame-three event previously passed against frame-four initiation. | Strict source ordering and a rejection mutation protect the new witness. |
| Engine automatic peer removal can precede SDK teardown. | Real physical run preserves game state but emits `remove_peer` engine errors; bare native peer reproduces them. | Guard both present/absent engine removal through the public SDK factory; test actual dynamic dispatch. |
| A fake caller dropping refused batches produces a false scheduling diagnosis. | Initial 12-frame stall disappears after exact retained ownership and post-delivery backlog measurement. | Retire the exploratory claim; preserve corrected scheduling evidence in the session log. |
| A scheduling model must preserve host return boundaries. | Fresh review finds readiness checked after delivery; the rerun also drains after failed gameplay. | Check readiness before yielding, skip work after failure, and measure every active delivery boundary before accepting metrics. |
| One slow service turn cannot necessarily drain amplified retries and ACKs. | Final both-pin default-budget fixture stalls after 14 frames with incoming peak 430; eight polls complete 16 with peak 28. All repetitions match. | Reuse bounded batching in actual waits, bind it with an executed host mutation, and retain the slower test in CI's integration tier. |
| Combining a heavy workload with ordering controls can exceed a process budget. | Both native CI jobs print correct backlog comparisons, then expire the combined 120-second watchdog. | Run all three cases separately with unchanged budgets and repeat layers; preserve a receipt for each. |
| Permanent relay traffic can exceed an inventory meant for one overlap proof. | The eight-peer physical room reaches frame 37 before ordinary ACK/input variants exceed 128 captured payloads. | Capture codec-validated early INPUT candidates, count all addressed envelopes separately, and preserve eligible-sample overflow rejection. |
| Artifact upload does not prove earlier steps passed. | A failed live probe still reaches its always-running upload step. | Read every step conclusion before claiming successful phase completion. |

## Prune and verification

Update the existing transport skill instead of creating another networking skill.
Retire context/table wording that calls all physical outage evidence planned;
retain explicit ICE restoration, replacement-channel and browser release limits.
The transport skill already owns retry-batch ownership, paired budgets and host
binding; the testing skill now adds exact readiness/yield ordering and complete
incoming-queue measurement to its bounded host batching guidance.

The native repro holds time fixed within each batch, while real host calls read
elapsed monotonic time. The fresh both-pin browser matrix supplies that missing
boundary. No arbitrary slow-caller throughput guarantee follows from these runs.
The integration tier keeps the 120-second process budget without enlarging the
unit or focused hang controls. Minimum/current repeated-process evidence and
`make llm-index lint-llm test-llm lint-source` verify touched guidance.

## Outcome

State: `findings-acted`.
Follow-ups: #75 live congestion/sustained routes, #38 ICE/lifecycle recovery,
#39 release browser matrix. Delivery remains subject to final-head CI and scans.
