# Retrospective: 2026-10-12 transport fallback

## Work under review

Carry forward the slow-mesh repair and add bounded per-peer direct/relay
fallback and restoration. This introduces a new transport capability and
requires independent review. Evidence lives in
[session 015](../../progress/session-015-transport-fallback.md).

## Findings and actions

| Finding | Evidence | Durable action |
| --- | --- | --- |
| Composition can bypass a lower adapter's terminal lifetime fence. | A fresh reviewer replaces `mesh.transport` without changing the plan. The initial coordinator publishes retained bytes through relay despite direct `WRONG_STATE`. The `transport_replacement` regression reproduces and protects the refusal. | Extend [networking guidance](../skills/networking-transport/SKILL.md): preserve terminal adapter fences when composing path switching. An explicitly accepted relay plan is a separate transition. |
| Output remaining queued is not evidence that direct unavailability continues. | `timer_recovery` starts unavailable, then sends directly at time 1 and still relays the tail at the old time-10 deadline. Actual successful direct dispatch now clears the timer before genuine refusal restarts it. | Extend the same guidance to reset pre-fallback clocks on demonstrated recovery and observe restoration readiness during idle polls. |
| Grace boundaries expose ownership transfers missed by ordinary timing tests. | Automatic review's `routing_lifetime` reproduces at zero and already-due grace: coordinator pending becomes 0 while relay pending becomes 1 before terminal refusal. | Check terminal lifetime fences before any route transfer; extend the existing composition rule rather than create another rule. |
| An aggregate poll error cannot attribute send unavailability. | `untried_tail` reproduces a healthy destination incorrectly relayed after another peer's actual send refusal. `receive_tail` exercises actual ACK pressure while retaining a healthy send-budget tail. | Track the actual refused destination; exclude inbound pressure and untried tails from fallback timers. |
| Small work budgets can leave a healthy recipient permanently behind a blocked recipient. | `fairness` uses three frozen identities and `max_routes_per_poll = 1`, retaining the blocked output while requiring healthy direct delivery. | Keep per-peer FIFO order and rotate bounded service through the frozen roster; record that bounded work does not prove fairness. |
| A passing package receipt can describe superseded bytes. | Rehashing both initial package archives detects the changed coordinator source. Full native executions started before final review fixes are stopped; final package and native checks restart after freeze. | Retain the existing testing source-binding rule rather than add duplicate guidance. |

## Prune ledger

Update existing transport guidance instead of adding a skill. Replace stale
planned-fallback wording in the context, PLAN and user guides. Preserve explicit
live browser, mesh-replacement, replan, suspension and release-matrix limits.
The initial package receipts and stopped native runs do not prove final-source
acceptance. The historical repair-head hosted run remains scoped to that head.

## Verification and outcome

Both engine pins pass the focused coordinator and actual three-peer game tests.
The direct-only mutation fails corrected canonical history and gameplay progress.
Initial independent review findings receive RED/GREEN regressions on both pins.
The second fresh review reports no verified defects, but automatic review then
finds two additional grace/pressure boundary defects. They reproduce RED on
4.7.2 and pass GREEN on both pins, followed by a new fresh review before delivery. Full frozen-source suites,
package bindings and hosted delivery evidence are recorded in the session log.
Harness regeneration and self-tests validate the guidance changes.

Live mixed-path browser acceptance remains tracked in issue #75 under S4/S5.

Retro: findings-acted.
