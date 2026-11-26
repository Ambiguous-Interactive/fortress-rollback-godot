# Browser relay failure boundaries

| Finding | Evidence | Action |
| --- | --- | --- |
| A quality round trip can coexist with a stalled input frontier. | Hosted Firefox Godot 4.3 run 45764484399 matched all 2,243 ACK payload digests. All but one ACK named frame 8. Each of 56 links kept sending frames 9–16. The newest raw report visible to the browser was about 20–23 server seconds behind the newest corresponding report write. | Stream exact input bytes at raw arrival, SDK delivery, and native admission beside the reverse ACK. Keep that evidence independent of the gate. |
| Firefox response start can identify an earlier boundary than the response bytes. | Six pages placed it near request start during a real 450 ms host delay. A bracket using network request start and response end replayed all eight valid receipts with post-handoff upper bounds of 4.56–4.94 ms. | Retain response start for diagnosis. Check the matching HTTP 204, the host handoff and the end of the response. Keep missing or contradictory timings explicit. |
| Optional calibration can starve the close snapshot that contains the proof. | A fixture with a first snapshot at 4,900 ms and a fresh abort at 4,925 ms failed when an optional HTTPS exchange consumed the remaining budget. The concurrent exchange let the abort prove closure. | Keep optional clock exchanges off the required snapshot retry path and retain the complete close checks. |
| Empty native input statuses hid a parser stride error. | A real 4.7.2 controlled expiry retained input 1252 and report 1260 after all eight published history. Both joined all six packet stages after validating the flag at the start of each seven-byte record. | Replay actual receipt bytes and exercise nonzero data adjacent to tags. Preserve missing upstream observations when retention cannot prove them. |

The [browser integration guide](../skills/testing/references/browser-integration.md)
uses the same clock and receipt boundaries. The
[Resource Timing specification](https://www.w3.org/TR/resource-timing/)
defines fetch and network request start as distinct observations.

State `findings-acted`.
