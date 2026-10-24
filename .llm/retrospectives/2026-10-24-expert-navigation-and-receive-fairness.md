# Retrospective: expert navigation and receive fairness

## Work under review

Session 074 advances expert replay navigation (#45), spectator relay recovery
(#131), and pressured peer-drop history publication (#188).
The work adds one request capability and repairs two bounded transport paths.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A priority liveness bypass can starve confirmed rows despite bounded receive work. | `test_signalfish_spectator_relay.heartbeat_fairness`: repeated keepalives fail original frontier assertion; one-shot control passes. | Limit priority bypass until ordinary queued work progresses; test one-packet budgets, blocked future rows and expiry equality. |
| Historical donor plans need recipient acceptance clocks independently of generic drop phases. | `test_peer_drop_history_pressure.partial_history_plan_retry`: original sender repeats to destinations `[1,2]` instead of refused `[1]`. | Preserve bounded per-link plan acceptance and exact retry timing. |
| Expert and callback checkpoint restore should use one validation engine. | `test_replay_expert_navigation` compares canonical state, malformed snapshots, metadata mutation, request lifetimes and bounded cache eviction. | Share ordered LOAD/SAVE requests and commit the restored frame only after exact validation. |
| A shared restore failure path changed cancellation's established frame diagnostic. | Existing `test_replay_expert.paused_termination` and `paused_termination_bad_result` report cached frame 6 instead of exposed frame 8 in CI. | Preserve cancellation at the exposed frame; ordinary restore faults still identify the attempted checkpoint. Include existing cancellation tests when reviewing shared request changes. |
| Verification during parallel authoring can observe a half-updated declaration inventory. | The exploratory reference-tooling run rejects newly declared `heartbeat_fairness` before the updated inventory loads. | Discard this preliminary gate; rerun source-bound checks after source freeze. Existing infrastructure guidance already requires a finalized snapshot. |

## Durable guidance and pruning

Extended the existing [transport procedure](../skills/networking-transport/SKILL.md)
with repeated priority traffic and one-packet fairness controls. Existing publication
acceptance-clock guidance already covers donor plans; no duplicate rule is needed.
The [request lifecycle procedure](../skills/rollback-fundamentals/SKILL.md) already
covers checkpoint termination and view expiration; clarified its distinct cancellation and restore-fault frame domains.

Considered old retrospective and knowledge entries: none of their contracts are
superseded by this additive API or these repairs. Keep source-comparison and live
spectator acceptance open in their original issues. No new browser support claim.

## Verification

Focused replay and spectator suites pass on both pinned engines. Fresh adversarial
reviews, full native/exported verification and delivery evidence are recorded in
the ignored session log and linked issues. Harness integrity, generated indexes,
source widths and harness self-tests run after this write.

## Outcome

State: `findings-acted`.
Remaining upstream drop trace parity, deployed spectator controls and full replay
acceptance remain in #188, #131 and #45.
