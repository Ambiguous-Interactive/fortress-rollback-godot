# Retrospective: 2026-10-26 clean spectator completion

## Work under review

- Scope: spectator relay completion classification and browser qualification.
- Trigger: a deterministic production defect found during an independent audit.
- Evidence: the existing relay suite's `post_completion` and `terminal_failures` cases;
  native red/green receipts in the local session log; exact native/browser comparisons.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A valid inner terminal result can become a false outer transport failure. | `signalfish_spectator_relay.gd` mapped every non-OK stream result; post-END polling returned PEER_FAILURE after successful playback. | Require completed authenticated END at the exact boundary before accepting normal termination. |
| Completion can happen inside a control sender, not only between polls. | The sender-callback regression returned PEER_FAILURE before repair. | Apply the same completion distinction after the callback and test queued late traffic. |
| Browser provenance must bind the executed path and staged source, not only the original files. | Independent PATH substitution and staged-source mutations evaded the first qualification candidate. | Execute the inventoried Node path; freeze staged sources, Godot, templates and browser inputs; verify each execution boundary. |
| Firefox exposed repeated owned diagnostic copies in a scalar confirmation fold. | The unchanged eight-player case measured 377.893 seconds; a scalar read measured 141.557 seconds with identical assertions. | Preserve current-read timing and public snapshot ownership; use narrow internal receipt and lifecycle queries. Verify the full batch, not only the isolated case. |
| Complete cases can still exceed page or whole-job deadlines. | CI completed a 195.256260-second batch; singleton jobs hit the 30-minute cap, and a four-case page completed at 180.549121 seconds. | Isolate slow cases, reassemble exact native records and use declared suite partitions; preserve every repeat, control and deadline. |
| Profiling disproved a broader transaction rewrite and located repeated identity lookups and handshake snapshots. | Identical eight-peer records measured 81.959 seconds baseline, 81.871 bank-copy variant and 63.136 combined narrow reads. | Reject the immaterial transaction rewrite; preserve atomic plans and use operation-local endpoint references. |
| Timed packet delay does not guarantee a prediction before original delivery. | CI preserved correct state but one peer never restored; a stale-lifetime mutation also defeated the first barrier. | Require successful current-instance predicted callbacks before releasing bounded originals; bind proof to room, session and game lifetime. |
| Corrupt rollback can stop a peer before later physical key changes arrive. | CI stopped at frame 38 with the second direction absent; local runs happened to accept it. | Await both second physical key changes while originals still bound advancement, then release; retain movement and desync assertions. |
| A provenance rejection needs both an input name and process-lifetime evidence. | Named diagnostics found the Firefox installation lock; an updater page reproduced creation, and pinned Juggler source waits for startup idle or window closure. | Close owned contexts before parent shutdown, retain every guard and record exit traces; original CI forced termination remains an inference in issue 226. |
| A shared diagnostic variable can change unrelated subprocess output. | Playwright DEBUG also made xdotool emit command lines; the strict JSON parser rejected the added data. | Remove only DEBUG and DEBUG_FILE from the copied xdotool environment, preserve parent tracing and reject extra JSON output. |
| Normal exit and context-first cleanup do not establish final destructor execution. | Merged main retained the updater lock after exit zero; the real late-mutex control fails at fast shutdown and preserves all runtime hashes at stage zero. | Request full shutdown in both Firefox launchers and retain a paired real-browser regression under the original inventory guard. |
| Automation can override the setting an experiment intends to compare. | Marionette replaced both profile-only settings with stage three. | Read the actual setting after initialization and during the tested callback; discard misconfigured comparisons as proof. |
| Parent exit does not establish completion of its owned process group. | A real child ignoring SIGTERM survived the first cleanup implementation after its parent exited. | Check descendants before final inventories and test cleanup when the parent exits before its children. |
| Clean playback does not prove clean continued transport service. | Existing clean-tail tests stopped before the next relay poll. | Extend the existing data-driven suite through repeated service, late ingress and SDK loss. |

## Actions taken

The [transport skill](../skills/networking-transport/SKILL.md) now requires tests after
actual playback completion, including completion inside control callbacks. Existing
input-closure guidance was replaced in place to avoid a duplicate rule and retain
its paused-tail authentication requirement. No state, replay or wire format changed.
The existing [testing evidence contract](../skills/testing/references/infrastructure.md)
already requires staged-source verification. Its enforcement belongs in the witness
and regression controls. Its existing budget paragraph now also requires complete
inventory coverage within the job deadline, with explicit partition identities.

## Prune ledger

- Fixed the incomplete transport guidance at its existing canonical paragraph.
- Retained separate clean input closure and unexpected-host-loss requirements.
- Reused the existing relay suite and ownership inventory; removed the exploratory test file.
- Updated the existing Firefox lock fact with its updater lifetime and context-first cleanup; no duplicate entry was added.

## Verification and limits

The regression fails before repair and all 26 relay cases pass twice on both engine pins.
The repaired online witness passed the full source-bound flow on both engine pins,
including actual current-room rollback, replay, outage recovery and corrupt-state rejection.
Its strict controls also cover stale game lifetimes and terminal room cleanup.
Session delivery also requires complete source-width, harness, ownership-browser and CI gates.
The local progress log records exact commands, receipts and final outcomes.
Live authenticated spectator control deployment and broader source parity remain under issues 131 and 47.
The [shutdown experiment](../../docs/experiments/firefox-shutdown.md) supersedes the
forced-termination hypothesis with paired real-mutex evidence. The exact original
asynchronous trigger remains inferred; runtime files are never excluded.

## Outcome

Retro: findings-acted
