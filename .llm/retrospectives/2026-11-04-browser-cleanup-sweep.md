# Retrospective: Browser probe cleanup sweep

## Work under review

A bounded sweep followed the spectator observer's operation/cleanup error repair.
It examined smoke, ownership, online and WebRTC browser runner lifetimes.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Browser-close rejection can skip server closure and keep Node alive. | Real entrypoint controls with live HTTP servers time out in smoke, online and WebRTC before repair. | Collect rejected browser closures, await every sibling and then close the server. |
| Nested cleanup can replace the primary error or another cleanup error. | Ownership loses primary/context errors; the nested WebRTC room reports only the first context-close failure. | Preserve all causes; include details where the outer logger renders only String(error). |
| Promise.all rejects before slower owned closures finish. | Delayed second-context and second-browser controls verify retirement before the next cleanup stage. | Use settled results and keep Firefox context-before-browser ordering. |

The existing [browser integration guidance](../skills/testing/references/browser-integration.md)
now requires complete sibling cleanup and awaited server closure. The earlier
cause-preservation rule remains authoritative; no duplicate skill was added.

## Verification

`test_browser_cleanup.py` executes the four actual Node entrypoints with browser
module doubles and live local HTTP servers. The entrypoint table covers 23 cases with healthy smoke
and ownership, primary failures, cleanup-only failures, combined failures and
slower siblings. Existing ownership tests retain Firefox shutdown ordering.
The WebRTC instrumentation fixture now implements the real server close callback.

Commands: Python unittest discovery for `test_browser_cleanup.py` and
`test_ownership_browser.py`; `node --test scripts/reference/browser/webrtc_instrument.test.cjs`;
source and harness lint. These controls prove cleanup behavior, not live browser qualification.

## Follow-up from PR verification

The initial local run selected only `webrtc_instrument.test.cjs`. Its server double
was updated, but the sibling `webrtc_watchdog.test.cjs` still had `close() {}`.
CI's combined three-file Node command therefore waited indefinitely for the
new close callback. The fixture now calls the callback; the exact combined
command passes 80 cases on pinned Node 26.12.1 and local Node 22.

The first subprocess tests checked stderr, which could preserve an earlier
operation log while `main()` rejected with cleanup errors alone. Eight VM cases
now inspect exact rejection and AggregateError member identities. Six fail on
the initial repair and pass when both runners retain the operation cause through
complete cleanup. The outer logger still renders every printable cause in its text.

A subsequent cold review found that diagnostic logging could throw and that
String conversion of a null-prototype rejection also throws. Both paths could
bypass the post-cleanup rejection. Diagnostic failures are now retained after
the operation cause, and reason formatting has a nonthrowing fallback. Seventy-two
VM cases cross both runners and nested room cleanup, Error/null-prototype/undefined/
number reasons, clean/throwing-console/throwing-JSON diagnostics and cleanup
success/failure. The initial 48-case matrix fails 30 cases before repair. Follow-up controls retain
rejected online diagnostic reads with null metadata, capture a coercion failure
once per value, and safely display opaque CLI rejections before resource ownership.
Exact coercion/error-object controls fail 18 baseline cases; diagnostic-read
controls fail four; early opaque CLI controls fail two with paired healthy runs.
Further catch auditing covers resource-closure diagnostics, named corruption
controls, spectator report publication and storage restoration without losing
the original rejection. CLI handlers set fatal exit status before reporting and
inspect without custom hooks or getters. Console file-write failures remain
owned fatal observations. Four command/event pairs now attach both rejection
handlers before starting their command; real Node children prove late errors
cannot escape cleanup. The final combined Node 26 gate passes 198 controls.

The full Python reference attempt completed 285 tests with 273 passes, ten skips
and two source-drift failures. Source and HEAD changed while it was running;
`source_changed` and `source_changed_during_capture` correctly rejected those
receipts. That attempt is not green evidence. Final focused verification runs
only after the candidate commit freezes source and Git identity.

The guidance now requires the complete CI control command and a sweep of dependent
callback doubles. These corrections qualify the affected control gate; they do
not claim the original spectator request failure has been resolved.

## Outcome

State: findings-acted. No request failures were suppressed and no healthy receipt
schema changed. Existing workload and process watchdogs remain required when an
actual browser or socket never completes shutdown.
