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

## Acceptance acknowledgment investigation

The actual `--acceptance-delay-ms 1500` browser control holds the response after
server acceptance. The old viewer departs and publishes success before release;
the repaired viewer waits, then preserves the same original canonical history.
The native sibling already waits, but its HTTP result also needs validation.
Holding the response beyond its three-second request deadline produces
`RESULT_TIMEOUT` (13), HTTP status zero, at about 3000 ms. The machine-local
`session154-accept-cause-output/held-response-observed/browser.log` records
1516975 to 4522105 microseconds: 3005 ms elapsed while the response hold is
configured for 3500 ms. This distinct timeout does not reproduce the intermittent
browser `ERR_ABORTED` cause tracked in #322. No error is suppressed.

The final frozen runtime/controller/CLI revision `773b2d7` passes the controlled
1500 ms hold on Godot 4.7.2 and Chromium 156. The native host retains 48 frames,
confirmed through 47; the stopped viewer retains frame 8 with nine buffered rows,
one accepted control, and no browser errors. The machine-local
`session154-accept-cause-output/final-frozen-green/spectator-live.json` receipt
has SHA-256 `99b98397bc5912eec3dba53205b1d26d034f048685ff63dea5369a43a278b99d`.
This scoped run does not establish minimum-engine or complete CI qualification.

Extended existing browser-testing guidance with the server-receipt versus client-
acknowledgment distinction. The retained regression controller verifies its actual
single held response, and both engine CI cells now select that regression. Admission-rejection
faults cannot combine with that hold because they never reach ACCEPT. The CLI
matrix fails before that guard and passes afterward.

## Review of acceptance observations

Trusted review found that final departure/success flags alone can miss gameplay
while the response is held. Route fulfillment also precedes the application's
HTTP completion callback. The real Node entrypoint matrix reproduces both
false positives against the initial helper: held-frame progress and departure or
success between response release and actual acknowledgment all pass incorrectly.

Publish each actual driver-step frame and a separate successful-HTTP callback
marker. Compare frames before forwarding ACCEPT and immediately before response
fulfillment; read acknowledgment only from the callback marker. The healthy
matrix progresses after acknowledgment, and a missing injection is rejected.
Fresh review also reproduces progress in a microtask after the last sampled
frame and before response delivery. A continuous frame setter now latches every
advance before actual acknowledgment, while preserving legitimate progress after
the callback even before the helper's fulfillment promise returns. The expanded
real Node matrix exercises both sides of this asynchronous boundary.
Existing browser guidance already distinguishes server receipt from completed
acknowledgment; this repair supplies the missing observation rather than another
parallel rule. Actual frozen-source browser qualification remains separate from
the Node process controls.

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
