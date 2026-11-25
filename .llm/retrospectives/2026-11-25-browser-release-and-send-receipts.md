# Browser release and send receipts

| Finding | Evidence | Action |
| --- | --- | --- |
| Firefox spent the hold budget waiting to enter the release evaluation. | Hosted receipts 14992228379 and 14992913245 show 8.31–8.59 s between controller dispatch and receipt of page entry. The page then spent 2.84–9.14 ms before starting the drain. Fifteen pages reached the 1,024-packet cap during release. | Prepare the browser requests before arming. Preserve the all-page readiness barrier, FIFO pace, cumulative caps and correction deadline. |
| Preparation readiness can outlive an HTTP response's socket. | The focused control printed `Missing expected exception: socket liveness precedes the response close event` when the socket was destroyed and its response remained live. | Keep the first response for each page and check both that response and its socket before publication. Fence late entry and deferred batches on the page clock. |
| WebKit's stack tag was generated before the native call. | Delaying tag construction by 5 ms gave `10000 !== 15000` in the exact-send control. Removing that delay made the baseline control pass. Appending another warning during collection produced `WebKit close evidence deadline for peer 1 channel 17`. | Record the send in a bounded per-page attempt history and request a fresh snapshot when another diagnostic arrives. Keep the 2 ms close margin and the separate SCTP abort proof. |

`python3 -m unittest scripts.reference.test_browser_cleanup` reported
`Ran 26 tests` and `OK`. `make lint-source` checked 598 files with zero
violations at 180 columns.

The browser integration guide now distinguishes controller dispatch, page
entry and FIFO service. It records the exact-send requirement beside the clock
interval guidance. Hosted Firefox and WebKit remain the release witnesses.

State `findings-acted`.
