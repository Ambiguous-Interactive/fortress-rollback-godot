# Retrospective: 2026-10-16 peer notices and capture

## Work under review

Session 026 advances client notifications (#40), usable canonical downloads (#42),
and safe SDK lifecycle handling (#38/#105). New user capability and SDK reentry
debugging trigger the retrospective. The [session log](../../progress/session-026-peer-notices-and-capture.md)
owns commands, red/green evidence, review dispositions and delivery results.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Correct prediction can become confirmed without rewriting its historical applied status. | `diagnostic_trace.gd` records applied statuses; `input_queue.gd` schedules correction only for differing bytes. The new `test_opt_in_trace_requires_consent_and_checks_original_history` status-2 control fails before repair. | Validate canonical state and original bytes below corrected confirmation; retain execution-time statuses. |
| SDK teardown can synchronously publish a new plan or end ownership before the outer call returns. | `test_signalfish_adapter_reentry.gd` reproduces room loss during attach and relay teardown, plan conversion after detach, nested valid plans during refusal, and replacement attach during teardown. | Release mesh ownership before SDK teardown, guard active teardown, and reject stale conversions with the lifetime revision. |
| Existing signal guard guidance applies to peer completion as well as local driver callbacks. | `test_peer_notifications.gd` exercises normal progress, repair-only stalls, terminal outcomes, callback failures and reentry. | Keep the peer guard held until completion handlers return; expose the final outer result. |
| Passing gameplay/download checks do not establish a usable UI layout. | The actual exported screenshot shows the new checkbox pushing status text over the playfield. | Position the playfield below the measured status area and inspect a fresh export before delivery. |

## Actions and verification

The [rollback skill](../skills/rollback-fundamentals/SKILL.md) now distinguishes
execution-time prediction status from current confirmation. The existing
[networking skill](../skills/networking-transport/SKILL.md) already requires
post-callback lifetime checks, so that procedure is not duplicated.
Public online and peer guides document opt-in payloads and notification ownership.
Fresh reviewers found adapter teardown gaps and the historical-status error;
regressions fail before repair and pass afterward. Fresh re-review is clean.
The broader native/browser gates and final immutable delivery evidence are
recorded in the session log and PR after they finish.

## Prune ledger

Removed stale public-guide statements that peer callers lack completion signals
and that online capture is always disabled. Kept the default privacy contract.
No new skill or knowledge topic was added. The testing skill is already 299 lines;
the semantic rule belongs in the shorter rollback skill, not in that general checklist.
No existing behavior claim is retired without its replacement regression.
Regeneration, harness lint and self-tests verify the guidance change.
The first broad integration command ignored the documented per-case entry point
and timed out. Its receipt is retained; verification switches to the exact CI
commands and existing deadlines. The testing skill already requires this, so no
duplicate rule is added. The runner guide's stale unit-budget claim is corrected.

## Outcome

- State: `findings-acted`.
- Follow-ups: full peer API parity (#40), broader diagnostic/replay workflow (#42),
  and live ICE/channel replacement (#38/#75) retain their existing acceptance gates.
