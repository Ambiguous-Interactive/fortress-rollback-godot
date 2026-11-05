# Retrospective: client usability

## Work Under Review

Session 158 advances peer integration #40, replay inspection #45 and spectator
viewing #47. Users can apply measured delay suggestions, select playback speeds
with letter shortcuts, and inspect readable spectator controls in short windows.
The trigger is new capabilities and a reproduced layout defect.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Fitting a dense scene by scaling its root makes controls unreadable. | The original spectator GUI scales to about 0.318 at 360×300; the new `readable_layout` case rejects that behavior. | Scroll controls at normal text size and fit game drawing separately; extend existing style guidance. |
| New keyboard controls need live GUI routing evidence. | `scripts/reference/replay_navigation_probe.gd::_replay_speed_keys` exercises button focus, text input, modifiers and held playback ownership. | Extend the existing deferred probe and preserve the deterministic canonical playback checks. |
| Parallel editing invalidates broad source-bound development receipts. | Peer and spectator development receipts report `source_changed` during concurrent edits. | Disqualify those receipts and qualify the frozen candidate; existing testing infrastructure guidance already covers this. |

## Prune Ledger

Searched existing style, testing infrastructure and GDScript knowledge before
extending the readable-control rule. Existing wheel propagation, source-freeze,
ownership and regression guidance remains authoritative. No duplicate skill,
new runner or source-parity claim was introduced. No stored claim was disproved.

## Outcome

Retro: findings-acted.
Broader driver/source parity, replay browser acceptance and live spectator
qualification remain in their existing issues. Session evidence is recorded
in the machine-local progress log and the session PR.
