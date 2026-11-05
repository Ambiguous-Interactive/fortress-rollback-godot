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

## Experimental aborted-request investigation

An isolated experiment branch retains source-only instrumentation; it is not a
shipping candidate or a repair for #322. The installed Godot 4.7.2 template's
actual `GodotFetch.free` removes its object and attempts `response.abort()` inside
a swallowed catch. The extracted implementation SHA-256 is
`f3c592d0423c06826e7844ac150a3c2144cff936aacb4390e37e50f6e0deeee5`.

On Chromium 156, 300 fully drained requests followed by engine free and forced
GC, plus partially read held-response free/retain controls, produce no request
failures. The original viewer's real plain and forced-GC timelines both show
reader EOF before successful HTTP result 0/status 200/body 17, followed by engine
free, physical departure, application success and SDK cleanup. Both retain the
original canonical histories with no browser errors. The plain timeline records
EOF 3788.85 ms, HTTP success 3802.51, engine free 3808.60, departure 3936.11,
application success 4118.99 and cleanup 4119.10. These timings describe this run,
not required thresholds.

Machine-local artifacts are `session154-fetch-lifecycle/result.log` and
`session154-fetch-rca-results/{plain,forced-gc}/spectator-live.json` under
`.cache/scratch`. The experiments run on arm64 and do not reproduce the failing
x86_64 CI schedule. They narrow explicit cancellation and immediate SDK cleanup
hypotheses; they do not prove that Chromium bookkeeping caused the observed
`ERR_ABORTED`, justify suppressing it, or qualify a root-cause repair.

Existing browser-testing guidance already separates correlated success from
complete control acknowledgment and forbids suppressing real network failures.
No new general rule follows from this non-reproduction; preserve the evidence
and its remaining uncertainty instead.

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
