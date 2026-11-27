# Chromium relay expiry timing

| Finding | Evidence | Action |
| --- | --- | --- |
| Exact TLS bytes alone did not order Chromium's socket read against the native expiry. | The timing fixture expected `before` and received no interval. On Linux, the real Chromium loopback then reported one negative, one overlapping and one positive interval. The busy page handled the overlapping carrier 677 ms after the TLS read. | Bracket the reporting document's monotonic clock before the match. Preserve the service turn and NetLog precision in the failure receipt. |
| Checking the computed interval alone admitted invalid timestamp magnitudes. | Review reproduced infinite bounds that returned `before`. It also found identical `Number.MAX_VALUE` operands that subtracted to zero and returned `after`. Both controls now return `unresolved`. | Validate each clock sample before arithmetic and reject an invalid computed interval. |
| One TCP read does not identify one WebSocket command. | Review showed that splitting the loopback's initial masked frame would advance its response index twice. | Place the first and final test writes after the page's ready and expiry markers. Use the page's sole WebSocket send to position the middle carrier inside the busy turn. |

The combined Chromium and Firefox loopback command reported `tests 10`,
`pass 10`, and `fail 0`. The Linux ARM64 Firefox runs on CPUs 0–2
passed both room sizes on each Godot pin. Mixed Chromium and Firefox
rooms on CPUs 3–9 also passed both sizes on each pin. Each eight-player
room matched 40 canonical rows and recorded all eight Leaves. These
attempts did not reproduce the historical natural expiry.

The [browser integration guidance](../skills/testing/references/browser-integration.md)
now applies one strict ordering rule to both source clocks and states the
separate Firefox capture and Chromium clock checks.

State `findings-acted`.
