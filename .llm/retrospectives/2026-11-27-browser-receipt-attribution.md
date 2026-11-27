# Browser receipt attribution

| Finding | Evidence | Action |
| --- | --- | --- |
| Promise continuations can reorder accepted history relative to native expiry. | A console fixture delivered valid history and then expiry in the same turn. The original report omitted the history. The revised fixture accepts the same-timestamp receipt with an earlier controller ordinal and rejects a later ordinal. A real 4.7.2 four-player targeted expiry retained 40 canonical rows, all four release and history milestones, and no intentional Leave. | Stamp sealed history in the listener. Keep page-local publication and controller receipt on their own clocks. |
| Browser cleanup can finish too late to save evidence or can throw after a valid join. | The real-entrypoint fixture originally recorded browser close first and later preserved the phase without its primary error. The current fixture sees the phase and original cause before cleanup. A simulated `rm` failure preserves the observed row. Malformed Base64 and decreasing TLS timestamps fail the corresponding controls. | Publish the phase immediately and hash the original line into any later socket evidence. Keep cleanup failure visible alongside the completed observation. |
| Chromium read completion identifies a receive boundary ahead of the handler. | A real TLS fixture observed the exact carrier 672 ms before the handler marker on Chromium's NetLog clock. Four- and eight-player rooms on both Godot pins compared 40 canonical rows, completed every Leave and joined at least one carrier on every directed link. | Keep the bounded socket capture opt-in. Independently require the frozen recipient and exact carrier on the same proxy tuple. Preserve unobserved rows when the rolling capture loses its source. |
| Firefox callback delivery can be late while the underlying frame timestamp remains useful. | Firefox 157.0 delivered Playwright's callback 550.467 ms after the loopback write. The same HAR's exact Gecko frame timestamp preceded the handler's outgoing acknowledgement by 550.534 ms. The first fixture closed before the acknowledgement and lacked that event. | Wait for both exact frame events in a timing control. The Firefox room still needs bounded collection that survives delayed or lost callbacks. |
| An isolated checkout can still share mutable browser tooling. | The 4.7.2 alternating room printed both pass lines and then rejected source identity. The shared Firefox executable's change time fell within the run. A provenance fixture now names changed inputs, including same-byte restoration. | Use a private Firefox tree for overlapping qualification. Keep the source-bound rejection and the precise changed path. |
| Matching payloads can attribute a previous send to a later retry. | The recording control reproduced the false match with two identical sends. After checking first send on the only WebSocket, both pins passed twice while forged two-socket receipts failed. Reading the patched buffer getter for telemetry also counted a refusal without an SDK read. | Retain bounded first-send history. Read the original getter for telemetry and leave the injected getter to the SDK. |
| Job duration omits time a job spends waiting for dependencies. | Run 45930154643 spent 83 s building the pinned server, and the last dependent browser job then spent 21 s on dependencies and 156 s on its witness. Rollout p95 was 276 s for 87 PR heads and 490 s for 52 merge candidates. | Trace the server-to-browser critical path using absolute job timestamps. Keep the newer 11-candidate window open for more evidence. |

The [browser integration guidance](../skills/testing/references/browser-integration.md)
now records when to stamp a validated history receipt, when to publish a failure
and how to isolate Firefox. It preserves the [existing archive
limits](../../docs/native-backend-migration.md) and replaces the shorter clock
rule that did not specify the controller acceptance point.

Firefox's [WebSocket receive source](https://searchfox.org/firefox-main/source/netwerk/protocol/websocket/WebSocketChannel.cpp)
creates the frame before dispatching the page callback. The pinned browser bundle
passes that frame timestamp through its internal debugging protocol. The public
Playwright callback used by the old control exposes the payload. The HAR probe
keeps the additional timestamp without treating callback absence as packet loss.

State `findings-acted`.
