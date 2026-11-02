# Retrospective: complete restarts and visible selection

## Work under review

Advance client integration (#40), replay inspection (#45) and local spectator
controls (#47). Replace the integration loop's partial restart, preview timeline
selection and expose the existing viewed-replay export through a pointer button.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Reconfiguring only the session leaves an advanced game, held sample and played-effect frontier attached to frame zero. | The original `examples/integration/loop.gd::start` reused these owners; the restart probe subsequently returned `CALLBACK_FAILED`. | Stage a complete replacement, retire the old session and support explicit fresh custom callbacks. |
| A slider can move without telling users which exact frame they selected. | The original `examples/online/replay_scene.gd::_timeline_changed` skipped refresh during dragging. | Show prospective frame/time separately from the displayed state and checksum observations. |
| Testing the real default export path can overwrite another process's recording. | The first spectator pointer fixture used the fixed `user://fortress-spectator.frrp` path. | Capture the existing export override in the unit test; run actual file receipt in a separate process with an owned data directory. |
| A repeated successful save can pass on stale bytes and a prior notice. | The original `_save_from_button` accepted an isolated mutant that refused stopped-viewer exports. | Require exactly one new export invocation per accepted press; the same mutant now fails that assertion. |
| Concurrent edits must disqualify a source-bound aggregate even when its selected assertions pass. | Focused replay/spectator records passed while native launchers reported `source_changed`. | Keep those records as diagnostic evidence and run final qualification only after the shared source freeze. |

## Verification and routing

Each change has a failing baseline control and passing focused cases on Godot
4.3 and 4.7.2. Live viewport input exercises timeline drag/release and spectator
saving; the native saved file reopens with its original canonical state.
Final frozen native and CI evidence belongs in the session log and linked issues.

Existing [rollback guidance](../skills/rollback-fundamentals/SKILL.md) already
requires staged replacement and retirement of prior owners. Existing
[infrastructure guidance](../skills/testing/references/infrastructure.md) already
covers owned native file paths, live GUI input and coordinated source freezing.
Extended the existing browser/UI observation guidance with per-action freshness,
alongside its prior-import readiness rule. No separate skill or knowledge entry is needed.

## Prune ledger and outcome

Removed the shared-file unit fixture before delivery. Considered the existing
playback-controls retrospective and source-image guidance; their contracts remain
valid and neither is superseded. The three parent issues retain their complete
upstream, platform and release acceptance requirements.

Outcome: `findings-acted`.
