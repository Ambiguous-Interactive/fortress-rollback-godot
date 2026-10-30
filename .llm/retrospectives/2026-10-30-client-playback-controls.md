# Retrospective: client playback controls

## Work under review

The session repairs integration input staging, adds recorded-checksum navigation,
and exposes runtime spectator viewing delay. It advances issues #40, #45 and #47.
The change exceeds 300 lines and includes a reproduced input-contamination bug.

## Findings

| Finding | Evidence | Disposition |
| --- | --- | --- |
| An inner BUSY result cannot reverse an outer controller's retained input. | `tests/unit/test_integration_controls.gd:74-80` compares genuine LEFT input after a refused nested FIRE call with an untouched canonical reference. | Apply the existing composed-service ownership rule to integration controllers. |
| Idle expert-staged input can reject a wrapper sample even when no callback or batch is active. | `tests/unit/test_integration_controls.gd:175-203` stages LEFT, rejects RIGHT and requires a corrected LEFT retry without changed controller state. | Validate retained input before wrapper caching, delivery and clocks. |
| Recorded checksum destinations and visited snapshot checkpoints serve different inspection needs. | `tests/unit/test_replay_input_navigation.gd:169-183` separates discovery from validation and navigates sparse/terminal checksums; `:210-231` rejects corrupt history. | Keep discovery separate from validation and delegate navigation to the existing bounded seek. |
| Delay changes need no new playback algorithm. | `tests/unit/test_spectator_demo.gd:757-786` exercises delay changes, bounded catch-up, pause, final-tail equality and restart through the existing viewer API. | Preserve pause, catch-up and clean-tail policy while changing only delay. |

## Actions taken

Integration controllers preflight ownership, terminal limits, retained input and
time before staging samples or advancing controller time. The continuation regression observes actual
canonical gameplay, in addition to unchanged controller fields. Rejection snapshots
include the shared session clock, so premature polling cannot hide behind a successful
retry at the same timestamp.

Replay navigation and spectator controls reuse existing playback contracts.
Their tests exercise actual visible controls and canonical state; the native/Web
ownership inventory includes every new case. Both UI screenshots were rendered
and inspected after layout.

## Prune ledger

The existing [rollback guidance](../skills/rollback-fundamentals/SKILL.md)
already required composed guards before clocks and samples, and terminal
preflight before staging. The first repair covered active owners but missed idle
expert-staged input. Extended that same ownership paragraph with candidate-sample
validation and a conflicting/corrected public retry. No separate skill or duplicate
knowledge entry was created.

The existing [browser guidance](../skills/testing/references/browser-integration.md)
already requires actual controls, selected-boundary validation and sparse/absent
checksum evidence. Those rules remain correct. Retired the overly broad rejected-call
documentation claim in favor of specific preflight guarantees; ordinary callback
failures preserve their established partial progress. Regeneration, harness lint,
harness self-tests and source-width checks verify the touched guidance.

## Verification

The integration original-source regression control fails at the intended
behavior assertions (11 live, 37 replay and 10 stopped-control assertions).
Replay and spectator original-source controls fail at missing feature or UI
assertions; these new capabilities have no claimed pre-regression baseline.
Focused suites pass twice on Godot 4.3 and 4.7.2, including in-process repeats:
10 integration cases, 22 replay cases and 25 spectator cases per fresh run.
Commands, receipt names and rendered screenshot checks are recorded in the
machine-local `progress/session-119-{client,replay,spectator}.md` logs.
A follow-up public-composition probe exposed the idle retained-input defect after
the first BUSY repair. Its added regression fails with 14 intended assertions per
internal live-controls iteration on the prior candidate
(`progress/session-119-client-input-red.json`). After the shared preflight repair,
all 10 integration cases pass twice on both pins, with internal repeats
(`progress/session-119-client-input-green43.json` and
`progress/session-119-client-input-green472.json`).
No pre-regression baseline is claimed for this pre-existing defect. A premature-clock
mutation passes the old rejection observer but fails six assertions per internal
iteration once the session clock is included. Both pins pass all ten focused
integration cases twice with that stronger observer; production remains unchanged.

Complete final native and exported verification, frozen source/tool hashes,
reviewed-head CI, feedback scans, merge and main-CI receipts belong in the aggregate
session log and linked issue updates. These delivery gates remain independently
required; focused results alone do not establish them.

## Outcome

Retro: findings-acted.
The broader source-parity and browser-release acceptance remains in the existing
issues; these local example improvements do not close those gates.
