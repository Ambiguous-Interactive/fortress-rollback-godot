# Retrospective: client playback controls

## Work under review

The session repairs integration input staging, adds recorded-checksum navigation,
and exposes runtime spectator viewing delay. It advances issues #40, #45 and #47.
The change exceeds 300 lines and includes a reproduced input-contamination bug.

## Findings

| Finding | Evidence | Disposition |
| --- | --- | --- |
| An inner BUSY result cannot reverse an outer controller's retained input. | `tests/unit/test_integration_controls.gd:73-78` compares genuine LEFT input after a refused nested FIRE call with an untouched canonical reference. | Apply the existing composed-service ownership rule to integration controllers. |
| Recorded checksum destinations and visited snapshot checkpoints serve different inspection needs. | `tests/unit/test_replay_input_navigation.gd:169-183` separates discovery from validation and navigates sparse/terminal checksums; `:210-231` rejects corrupt history. | Keep discovery separate from validation and delegate navigation to the existing bounded seek. |
| Delay changes need no new playback algorithm. | `tests/unit/test_spectator_demo.gd:757-786` exercises delay changes, bounded catch-up, pause, final-tail equality and restart through the existing viewer API. | Preserve pause, catch-up and clean-tail policy while changing only delay. |

## Actions taken

Integration controllers preflight ownership and terminal limits before staging
samples or advancing controller time. The continuation regression observes actual
canonical gameplay, in addition to unchanged controller fields.

Replay navigation and spectator controls reuse existing playback contracts.
Their tests exercise actual visible controls and canonical state; the native/Web
ownership inventory includes every new case. Both UI screenshots were rendered
and inspected after layout.

## Prune ledger

The existing [rollback guidance](../skills/rollback-fundamentals/SKILL.md)
already requires composed guards before clocks and samples, and terminal
preflight before staging. Its rule was correct; another duplicate rule would
add no durable knowledge (lines 137-138 and 154-158).
The existing [browser guidance](../skills/testing/references/browser-integration.md)
already requires actual controls, selected-boundary validation and sparse/absent
checksum evidence (lines 15-31). No guidance was retired or duplicated.
No skill or knowledge entry changed, so verify-on-touch of stored commands is
not applicable. Fresh-context curation inspected these owning entries before
considering a new knowledge home; all three findings reinforce existing rules.

## Verification

The integration original-source regression control fails at the intended
behavior assertions (11 live, 37 replay and 10 stopped-control assertions).
Replay and spectator original-source controls fail at missing feature or UI
assertions; these new capabilities have no claimed pre-regression baseline.
Focused suites pass twice on Godot 4.3 and 4.7.2, including in-process repeats:
10 integration cases, 22 replay cases and 25 spectator cases per fresh run.
Commands, receipt names and rendered screenshot checks are recorded in the
machine-local `progress/session-119-{client,replay,spectator}.md` logs.
Final full native, exported ownership and delivery checks remain owned by the
session lead; their completion must be recorded in the aggregate session log
and issue/PR evidence before delivery. Focused results alone do not establish
those gates.

## Outcome

Retro: findings-acted.
The broader source-parity and browser-release acceptance remains in the existing
issues; these local example improvements do not close those gates.
