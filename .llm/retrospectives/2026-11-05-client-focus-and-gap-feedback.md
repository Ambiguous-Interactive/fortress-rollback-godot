# Retrospective: client focus and gap feedback

## Work Under Review

Session 155 addresses client inspection in issues #40, #45 and #47.
The effects match and replay viewer pause on focus loss; paused spectator
feedback identifies retained gaps. Core simulation and formats are unchanged.
The trigger is a new client capability and regression investigation.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Focus pauses must respect active request ownership and player replacement. | `examples/online/replay_viewer.gd`, controller-owned request-boundary pause; `tests/unit/test_replay_speed.gd`, retained expert batch case | Add this procedure to the existing GDScript style skill. |
| Parallel source editing can invalidate otherwise passing local probes. | Spectator and driver focused receipts report source drift or host-capacity contention. | Preserve disqualified receipts and run final aggregate tests after source freeze; existing infrastructure guidance already covers this. |
| Repeat can own an automatic seek while ordinary playback is false. | Cold reviewer reproduced unfocused resume through a selected range; `tests/unit/test_replay_speed.gd` now crosses focus with the internal seek. | Extend the focus pause to cancel pending automatic resume; preserve explicit seek completion. |
| Accelerated playback can begin several request lifetimes inside one UI tick. | Second cold review delivered focus inside the first 4× simulation callback and observed three extra advances. | Apply deferred pause at the request boundary, not only the next UI tick; extend style guidance. |
| Mutating the original recording does not corrupt an owned imported copy. | Replay negative control now corrupts serialized input before opening it. | Retain the installed-decoder control; existing infrastructure guidance already requires serialized corruption. |

## Prune Ledger

Searched existing skills and knowledge for focus pause guidance; no duplicate
procedure existed. Extended the existing style skill with focus, ownership and automatic-resume boundaries.
Existing concurrency and serialized-corruption guidance remains authoritative;
no duplicate skill or broader network-pause policy was added.
No obsolete claims were removed. Regeneration, harness checks and frozen-source
native verification are recorded in the local session log and linked issue evidence.

## Outcome

Retro: findings-acted.
Broader driver equivalence, replay source/platform parity and live spectator
acceptance remain in their original issues.
