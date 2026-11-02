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
| Raw descriptive text and incompletely escaped JSON can change diagnostic status lines | Scene tests plus a live Label show U+0085/U+2028/U+2029 adding lines after JSON quoting | Extend the existing metadata rule with explicit codepoint and actual Label checks; no duplicate skill |

## Prune ledger

Searched existing testing, style and copy guidance before editing. Metadata escaping and
terminal preflight already have canonical rules; the escaping rule now records Godot’s serializer limit. No competing guidance was added.
No obsolete source claim was found. Browser shortcut testing now extends its existing home.
Regenerate and validate the harness; full source-frozen verification remains a delivery gate.

## Outcome

State: findings-acted. Broader parity, live relay and release gates remain in the existing
parent issues; scoped UI and controller repairs do not close them.
