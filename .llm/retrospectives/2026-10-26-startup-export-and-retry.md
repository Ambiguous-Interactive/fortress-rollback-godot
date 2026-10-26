# Retrospective: Startup state, export validation and retry deadlines

## Work under review

Session 088 advances spectator initial-state agreement, malformed replay export rejection,
and coordinated-drop READY publication under partial refusal.
The debugging and capability changes require this retrospective.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Same-time drains hide shared retry gates shifting independent link deadlines. | The fresh history review exercised actual READY service: acceptance at 0 and 25000 microseconds suppressed the first link at 50000 until 75000. | Extend the existing transport testing rule with staggered acceptance times. |
| Playback validation does not protect portable exports from caller-mutated storage. | The existing replay configuration rejection table produced 28 export failures before the guard. | Validate structure and digest storage at export; preserve content evidence for playback. |
| Matching seeds and rules do not establish identical original game state. | The initial-state agreement case changes one same-length snapshot byte before authenticated startup. | Add an explicitly state-bound digest helper and require canonical state in network integration guidance. |

## Prune ledger

Updated the existing retry-boundary rule in the owning
[transport skill](../skills/networking-transport/SKILL.md), rather than adding a competing procedure.
The legacy configuration digest remains documented because callers and frozen goldens still use it;
network startup guidance now selects the state-bound helper.
No existing runtime/parity or live-browser claim is retired without replacement evidence.

## Verification

Replay and spectator focused suites pass on both engine pins. Revised history pressure cases
pass on current Godot, including staggered acceptance and minimum-capacity donor controls.
Fresh independent reviews pass for all three scoped changes. Full native, exported Chromium
and CI delivery evidence belongs in the machine-local session 088 progress log and linked issue updates.
Broader pinned-source, live spectator relay and release-platform acceptance remain on #188, #45 and #131.

## Outcome

Retro: findings-acted
