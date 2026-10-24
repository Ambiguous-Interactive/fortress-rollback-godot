# Retrospective: playback and drop pressure

## Work under review

Session 073 advances peer-drop recovery (#188), spectator ingress (#131), and
expert replay validation (#45). Production changes preserve bounded work,
original confirmed history and existing replay formats.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A future spectator row can block the earlier row needed to release playback capacity. | `test_signalfish_spectator_relay.reordered_recovery` fails on the original FIFO path while its ordered control passes. | Retain exact refused packets and scan with a persistent bounded cursor; test budgets one/two and multiple blocked rows. |
| A refused drop control must not consume its retry clock. Partial acceptance also needs separate recipient clocks. | `test_peer_drop_capacity` uses actual queued ACKs to refuse prepare, inventory and commit; four peers exercise partial publication. | Gate retry timing on acceptance and track the bounded set of recipient publication times. |
| Callback paused validation left expert clients without equivalent request dispatch. | `test_replay_validation` compares canonical playback, checksum coverage, failures and view lifetimes through both APIs. | Add a save-only expert validation batch using the existing checkpoint acceptance gates. |
| Runner case filters do not select whole suites by suite filename. | The exploratory `--filter replay` run selected five cases, while the new suite has a separate explicit receipt. | Exclude that run from broad coverage claims; full native and exported inventories remain delivery gates. |

## Durable guidance and pruning

Updated the existing [networking procedure](../skills/networking-transport/SKILL.md)
with the distinction between authenticated spectator application reordering and
protocol FIFO requirements. Its existing partial-publication clock guidance already
covers the drop failure class; no duplicate rule or new skill is needed.
The existing [test infrastructure guidance](../skills/testing/references/infrastructure.md)
already requires exact case inventories; no second filtering rule is needed.
No obsolete claims were removed; the new API and receive behavior are documented
at their existing integration and spectator guide locations.

## Verification

The spectator and replay focused suites pass on both pinned engines. Fresh
adversarial reviews report no findings and run independent focused checks.
Full native/exported verification, final drop review and remote delivery evidence
are recorded in the machine-local session log and linked issue updates.
Harness integrity, source widths and harness self-tests are required after this write.

## Outcome

State: `findings-acted`.
Deployed spectator control/routing, full pinned drop trace comparison and complete
replay source acceptance remain in their original issues. Scoped repairs do not
establish complete advanced-feature parity or broaden browser release claims.
