# Retrospective: Client history and viewer replacement

## Work under review

Session 068 advances client-driver history access, replay integration and spectator restart safety.
The trigger is a reproduced spectator lifetime defect.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Fencing stream delivery alone leaves retained old drivers able to play buffered rows. | `spectator_stream.gd:67` now retires the old owned viewer; `test_spectator_stream.gd` case `replaced_viewer` fails five intended assertions without it. | Extend the existing networking lifetime guidance to cover retained playback owners. |
| Exposed child sessions can acquire independent lifetimes. | The same regression directly reconfigures the exposed viewer and proves a later stream restart cannot terminate it. | Keep configuration identity as the ownership guard; avoid unconditional termination. |
| A detailed replay audit can legitimately produce no code changes. | The actual pinned replay oracle passes 22 cases and rejects 13 controls; focused replay tests pass. | Preserve existing format and validation contracts; report remaining release gates honestly. |

## Verification

The spectator suite passes on Godot 4.3 and 4.7.2 after the fix.
Driver history tests cover correction-time privacy, owned replay replacement and physical ring wrap.
Fresh adversarial review of the complete production diff reports no findings.
The session log records full-suite, browser, lint, CI and delivery results as they finish.

## Prune ledger

Updated the existing transport lifetime paragraph instead of adding a duplicate skill.
Its prior delivery/expiry rules remain valid; retained drivers add a distinct consumer boundary.
No stale guidance was found to remove. No platform or full-parity claims were expanded.

## Outcome

Retro: findings-acted.
