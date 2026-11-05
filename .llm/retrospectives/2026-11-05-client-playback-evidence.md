# Retrospective: client playback evidence

## Work Under Review

Session 159 advances effects replay inspection, browser chooser acceptance and
spectator delivery comparisons. Debugging and verification changes trigger the loop.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Focus pause must cover each playback mode. | `examples/integration/integration.gd::_physics_process` originally serviced replay before the live pause gate; regression observed frame 3 advancing to 8 during five background ticks. | Give replay its own pause and reuse pointer/keyboard inspection controls. |
| Temporary ownership can erase clean completion even when failure codes stay healthy. | Fresh adversarial reproduction: completed replay, live capture batch, service during ownership, release; the replay status became OK and controls re-enabled. | Preserve terminal replay result across ownership and clarify existing scene-status guidance. |
| Expected failure text can hide unrelated cleanup failures. | Fresh review reproduced an AggregateError containing the expected mutation diagnostic and a cleanup rejection; a substring matcher accepted it. | Require the expected failure to be the sole top-level error and reject combined failures. |
| Browser event completion can precede the next rendered observation. | Firefox delivered the chooser event while the last fixture snapshot still reported playing; a synchronous observation command reads actual controller state. | Preserve the original failure and add a paired stale-publication regression before rerunning the browser matrix. |
| A recorded browser error must join an already-failed operation before qualification. | Final cold review reproduced an expected chooser exception hiding a console/page error retained only in a side array. | Fold typed captured errors into final failures after cleanup and event drain; intentional error controls require an acknowledged exact singleton injection. |
| Native picker evidence does not establish browser interaction. | Existing exported download harness already receives real picker events; chooser extension tests ordinary playback, Repeat, cancellation, rejection, fractional resume and replacement through that path. | Extend the existing harness and export an exact production-call omission control with independent hashes. |

## Actions Taken

The existing [GDScript style skill](../skills/gdscript-style/SKILL.md) now makes
terminal-result preservation across temporary ownership explicit.
The effects regression and live GUI witness cover independent replay pause.
Browser mutation export verifies tool and staged inventories, restores healthy
source bytes even after failures, and binds the control to its separate export.
Focused export-helper controls reject missing targets, export failures, tool
changes and sibling source drift.

## Prune Ledger

Existing pause, source-freeze and browser evidence guidance was searched first.
The new terminal-status line extends that guidance; no parallel skill was created.
No prior operational claim was disproved or retired. Historical experiment and
carry branches remain intact; cache growth is reported without deleting evidence.

## Outcome

State: findings-acted. Full roadmap source/browser release acceptance remains in
the existing task issues. Session progress and final CI receipts stay machine-local.
