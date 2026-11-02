# Retrospective: input ownership and shortcuts

## Work under review

Three user-facing investigations cover online input ownership, replay/diagnostic inspection
and spectator controls. Changes repair controller preflight, keyboard guards and imported
metadata presentation. Evidence lives in the deterministic regression suites and session 141 log.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Unhandled input still carries browser/editor modifier combinations | `test_example_shortcuts.gd` and `test_spectator_demo.gd` fail when guards are absent; live offline Ctrl+R replaces the scene | Extend existing browser-integration test guidance with modifier, release, echo and ordinary-action controls |
| New recoverable-input guards can conceal an earlier terminal cause | Fresh review reproduces staged RIGHT, termination, then LEFT bypassing terminal reporting | Require terminal-conflict regression through both online facades; retain existing rollback terminal-preflight guidance |
| Raw descriptive text can change the apparent diagnostic status | `test_diagnostic_viewer.gd::scene_controls` fails on newline/control seed text | Apply the existing bounded plain-text metadata rule; no duplicate skill |

## Prune ledger

Searched existing testing, style and copy guidance before editing. Metadata escaping and
terminal preflight already have canonical rules; no competing guidance was added.
No obsolete source claim was found. Browser shortcut testing now extends its existing home.
Regenerate and validate the harness; full source-frozen verification remains a delivery gate.

## Outcome

State: findings-acted. Broader parity, live relay and release gates remain in the existing
parent issues; scoped UI and controller repairs do not close them.
