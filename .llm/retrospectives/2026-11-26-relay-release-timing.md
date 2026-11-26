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

State `findings-acted`.
