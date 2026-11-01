# Retrospective: confirmed effects and paused inspection

## Work under review

Session 137 addresses the driver integration boundary (#40/#300), replay
inspection (#45), and local spectator controls (#47). The change adds two
client capabilities and repairs an application-hook ownership defect.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Driver callback completion does not end a composed controller's ownership when application effect hooks still run. | `examples/integration/loop.gd` called `effects.reconcile()` after `driver.step()`; `test_integration_effect_reentry.gd` reproduces accepted nested mutations in immediate and delayed final-tail effects. | Keep shared session notification ownership through effects and test cancellation followed by reentry. |
| Paused inspection must distinguish input integrity and cached evidence from recorded state validation. | `test_replay_viewer.gd::paused_validation` crosses checksum-free, initial and terminal boundaries without advancing input. | Reuse existing player validation and display its existing coverage status. No second validation policy. |
| Controller calls cannot prove pointer routing or layout. | Both new controls have native live-scene mouse witnesses on both supported engine pins and inspected screenshots. | Apply existing live-UI testing guidance; no duplicate rule needed. |

## Actions taken

The application-hook lesson extends the existing shared ownership guidance in
[rollback fundamentals](../skills/rollback-fundamentals/SKILL.md).
The implementation uses the existing session guard and existing validation and
policy APIs. The ownership probe inventory includes the new regression suite
and replay validation case for native/exported execution.

Focused red/green receipts and live UI witnesses are recorded in the local
session log. Immutable current-head CI remains the final delivery gate;
source edits during a local full run disqualify that run under #298.

## Prune ledger

- Searched existing skills and knowledge for effect/presentation ownership.
  Existing notification guidance was correct but did not cover post-driver hooks.
- Extended that canonical paragraph rather than adding a competing skill.
- Retained existing UI, callback, deterministic and source-freeze guidance.
- No prior accepted source or release evidence is retired by this change.

## Outcome

Retro: findings-acted.
Broader driver, replay, spectator and browser acceptance remains in the parent issues.
