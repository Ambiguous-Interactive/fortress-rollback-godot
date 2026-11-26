# Relay release timing

| Finding | Evidence | Action |
| --- | --- | --- |
| The host write and the page continuation can be delayed independently. | The Firefox 157.0 HTTP control delayed the write by 450 ms. It measured 454 ms to the write and 1 ms from response end to continuation. The page control measured a prompt write and 453 ms after response end. | Match the exact fetch before it starts. Keep host timestamps apart from page timestamps. |
| The page can publish the resource timing after it resumes. | The browser entrypoint fixture delays the resource callback until after the continuation. Both receipts survive final diagnostics timeouts. The control also accepts the reverse arrival order. | Retain a bounded receipt for each event. Capture the continuation at entry and publish it after the synchronous start of release. |
| A failed HTTP response still resumes the page. | The 409 control reports the status and continuation while retaining the existing release refusal. | Store the status on the same continuation receipt. Keep unavailable timing fields null. |
| A pending promise can leave a control unfinished while Node exits successfully. | A release that never resolves exited 0 before the guard. It now exits 1 with `relay release timing control did not finish`. | Check completion at `beforeExit` when an asynchronous fixture owns no persistent handles. |

The [browser integration guide](../skills/testing/references/browser-integration.md)
now covers independent release observations with the same guidance as retained
close stages. The [migration contract](../../docs/native-backend-migration.md#session-boundary)
defines each clock and replaces the dispatch-to-entry interval as the only
measure of release latency.

The hosted Firefox 4.7.2 room hit the cap on every page before Resource Timing
reported response end. Continuations arrived another 3.85 seconds later.
Controller writes began within 0.98 ms of dispatch. The cap and response
ordering show why controller timing alone misses both delay boundaries.
The 4.3 room hit the cap before the controller dispatched release while it
waited for matched control replies. The local Firefox rooms, hosted Firefox
four-player controls and hosted Chromium eight-player controls passed both
pins. Keep the failed hosted boundaries distinct in the follow-up.
[Hosted Firefox rooms](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45752366186)

State `findings-acted`.
