# Retrospective: client playback controls

## Work under review

Session 154 advances client integration, replay inspection and spectator controls
under issues #40, #45 and #47. New controls require deterministic state evidence
and actual deferred GUI routing. Broad source and live-browser acceptance remains
with the original issues.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Whole-recording repetition and selected-range repetition have different lifetime semantics. | `examples/online/replay_viewer.gd`: selected rewinds use bounded `seek`, which can restore validated checkpoints. | Correct the repeat API comment and guide to distinguish fresh whole-recording playback from selected navigation. |
| A selected repeat can begin from the completed final boundary. | Fresh adversarial review reproduced start 2/end 8 refusing Play while start 2/end 7 works. | Add a boundary regression and align controller and scene playback readiness. |
| GUI wheel tests need a visible hit target after each layout change. | The added selection row moved the slider outside the fixed-scroll test position. | Center the actual slider, settle layout, and assert viewport containment before each wheel event. |
| Finalization must describe the retained recording separately from the completed match. | `tests/unit/test_integration_finish.gd`: empty and capped recordings retain only existing evidence. | Show omitted-ending feedback; capture terminal checksums only when the recording covers that boundary. |
| Concurrent authored-source edits invalidate an otherwise unrelated native run. | Native launcher refused a mixed-source focused attempt during GUI edits. | Preserve the refusal and qualify the final combined source after all edits stop. |

## Curation and pruning

Existing testing guidance already covers source freezing, actual GUI routing,
layout settling and exact staged inventories. No duplicate skill or fact is
needed. Remove the obsolete universal fresh-lifetime claim at its owning API;
keep the original broad issue acceptance and platform limits explicit.

Verification commands: `make lint-source`, `make lint-llm`, `make test-llm`,
and `bash progress/session-154-verify.sh`. Frozen native receipts are written to
`progress/session-154-<engine>-<category>.json`; each binds executed source bytes.
The [local session log](../../progress/session-154-client-playback-controls.md)
records candidate identity, process exit status, reviews and final CI evidence.
These local artifacts are intentionally excluded from the distributed addon.

## Outcome

Retro: findings-acted
