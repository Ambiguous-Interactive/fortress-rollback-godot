# Qualification receipt bounds

| Finding | Evidence | Action |
| --- | --- | --- |
| A response end timestamp needs evidence of a successful response. | The Resource Timing specification also gives aborted fetches an end timestamp. A simulated 204 continuation received before the controller's first write gave a false interval until the causal check was added. | Require a recorded HTTP 204. Bound the latest browser response end by controller receipt of the resource record. |
| Firefox response start can precede the host's first write. | In the local Godot 4.3 eight-player room, seven of eight successful requests reported a response start at least 581 ms before host write even at the latest allowed clock offset. | Keep response start in the raw receipt. Use the successful response end for delivery. |
| Transport delivery and page continuation can be delayed independently. | Firefox 157.0 with a 450 ms HTTP proxy delay measured delivery in [442.35, 455.05] ms and 1.36 ms for continuation. A 450 ms page delay measured delivery in [0, 4.17] ms and 451.56 ms for continuation. | Exercise both boundaries independently and preserve the clock bracket. |
| One failed WebKit snapshot hid fresh clock samples and exact send times from successful reads. | The partial-round fixture returned stale clock bounds before repair. Its 1,999 µs and 2,000 µs controls both fail the qualification as incomplete rounds. | Keep the latest timely diagnostics and any earlier complete proofs. Require a complete round for acceptance. |
| Background npm scripts preserve lifecycle record boundaries. | With npm 11.20.0 and foreground scripts, a script emitted a completion lookalike after an unterminated stdout fragment. With background scripts, npm emitted separate start and completion records and suppressed both script writes. | Disable foreground scripts for the global install and accept only whole npm lifecycle records. |
| npm lifecycle markers localize a timeout without printing npm's free text. | Cold ARM64 installs used Node 26.12.1 and npm 11.20.0. The OpenCode 2.4.2 baseline passed in 8.806 s and the diagnostic path passed in 11.228 s. Fake acquisition, postinstall and post-lifecycle stalls timed out with different phase evidence. | Publish aggregate timing and lifecycle phase markers. Keep the historical intermittent timeout open for an observed recurrence. |

The [browser integration guide](../skills/testing/references/browser-integration.md)
replaces the earlier general clock advice with the receipt-specific boundaries.
The [W3C Resource Timing specification](https://www.w3.org/TR/resource-timing/#sec-performanceresourcetiming)
defines the page observations.

State `findings-acted`.
