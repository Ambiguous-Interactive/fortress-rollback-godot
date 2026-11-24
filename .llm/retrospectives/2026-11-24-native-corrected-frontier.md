# Corrected frontier and room departure

| Finding | Evidence | Durable action |
| --- | --- | --- |
| A rollback correction can arrive long before enough input is confirmed to compare history. | On three CPUs, Firefox 4.3 `relay:8` reported corrections on all pages and then `absolute native corrected history deadline`. The final heartbeats showed frame 40 and confirmation 32. The four-player room compared all 40 frames. | Take the first eligible sample at the end of the physics turn. Keep the frontier, advancing turn, publication and receipt separate in the [browser witness guidance](../skills/testing/references/browser-integration.md). |
| A target or remote identity can reach the controller after its page event. | The focused browser control backfills target 44 from a page observation at 25 ms, emitted at 27 ms and received at 127 ms on the controller clock. It delivers a second SDK removal despite ten copies of an early receipt. | Bound pending observations and preserve their original times. Check the actual comparison target and hold baseline before retaining a frontier. Bind pending departures to the frozen members before using them. |

The focused command
`python3 -m unittest discover -s scripts/reference -p test_browser_cleanup.py -k post_release_checkpoints -v`
first failed because no frontier receipt existed. The revised control passed
with diagnostic reads unavailable. It rejects pre-readiness samples and
unrequested targets, preserves the first advance, and checks departure
identity. This supersedes using the final heartbeat to estimate when a
peer first confirmed the comparison target. Firefox qualification remains
tracked in #458, #484 and #486.

State `findings-acted`.
