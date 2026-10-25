# Retrospective: client input and failure boundaries

## Work under review

Session 082 addresses spectator host lifetime fencing (#208), peer retained
input reads (#40), and replay callback failure diagnosis (#45).
The trigger is production debugging and more than 300 changed lines.

## Evidence and findings

| Observation | Evidence | Disposition |
| --- | --- | --- |
| SDK identity getters can synchronously end a publication lifetime without changing identity values. | `test_signalfish_spectator_host.gd`, paired `callback_lifetimes` controls: nine signals at protocol, setup getter and runtime getter boundaries. Original source publishes; repaired source rejects without sending. | Existing networking guidance already requires setup listeners and post-callback lifetime checks. Apply it to the host. |
| A peer client needs the exact staged sample after partial network publication. | `test_peer_session.gd`, `scheduled_inputs` and `partial_publication`: grouped slots, delay, prediction pressure, output pressure, recovery and owned reads. | Delegate the accessor to the existing core; retain one staging authority. |
| Replay callback failures need an operation as well as a frame and result code. | `test_replay_callbacks.gd`, `failure_kinds`: callback/expert SAVE, LOAD and ADVANCE failures, paused validation, navigation and explicit termination. | Record the authoritative request kind at failure; do not trust caller-mutable request metadata. |

Each new feature has an intended failing baseline assertion. Paired host controls
preserve unchanged connection and identity values. The shared ownership witness
includes every new case for native and exported Chromium execution.

## Curation and pruning

Searched the existing skills and knowledge before considering additions.
[Networking conventions](../skills/networking-transport/SKILL.md) already cover
the setup/getter hazard and first-failure preservation.
[Rollback conventions](../skills/rollback-fundamentals/SKILL.md) already require
owned request lifetimes and preserved diagnostic causes.
No new general procedure is needed. No existing claim was contradicted, and no
duplicate guidance was added or retired.

Three fresh adversarial reviewers inspect the separate runtime changes.
The local session log records test receipts and delivery evidence.

## Outcome

Retro: no-findings

Terminal replay checksums remain under #205. Full replay, driver and live
spectator acceptance remain with their original issues; these scoped repairs do
not establish complete upstream or browser release parity.
