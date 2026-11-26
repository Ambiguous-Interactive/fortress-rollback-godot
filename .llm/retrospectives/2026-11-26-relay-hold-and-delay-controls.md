# Relay hold and delay controls

| Finding | Evidence | Action |
| --- | --- | --- |
| A release control must reach and measure its selected boundary. | Four exported Firefox rooms printed `relay:8 passed`. Delayed host handoff measured 450.73–450.80 ms on Godot 4.3 and 450.84–450.90 ms on 4.7.2. Page delay after Fetch resolution measured 450.20–538.80 ms and 450.18–537.80 ms. Each room matched 40 inputs and snapshots and completed eight corrections and leaves. | Run the stock room and each delay on the same hosted runner. Keep every attempt, including failures before the stimulus. Require the measured interval in a passing receipt. |
| Delaying HTTP completion and delaying the page affect independent stages. | The timer fixture rejects the release after the original deadline on both clocks. It also rejects a 500 continuation even with a 204 resource entry. | Hold the prepared headers until HTTP completion for delivery. Delay after Fetch resolves for continuation. Keep the original absolute deadlines. |
| A page snapshot timeout can hide a live relay backlog. | In the Godot 4.3 hosted eight-player failure, the final page reads timed out after every page reported zero matched control replies. The new limited fixture records an exact report and reply on both directed links without the final page read. | Publish bounded page batches during the hold. Retain ambiguous echo candidates and join exact server stamps when available. |
| Availability and timing are separate WebKit proof gaps. | All nine unresolved hosted sends had a unique reciprocal link. Upper-bound intersections from console receipts still proved zero of nine. One room delivered all snapshots before exhausting the proof deadline. | Compare page clocks without relaxing the completed close or abort proof. Track snapshot and renderer failures separately. |

The [browser integration guide](../skills/testing/references/browser-integration.md)
uses same-runner comparisons that retain failed attempts. The
[HTTP documentation](https://nodejs.org/api/http.html#outgoingmessageflushheaders)
describes why preparing headers can precede socket handoff.

State `findings-acted`.
