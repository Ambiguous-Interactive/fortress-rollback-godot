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
module doubles and live local HTTP servers. Fourteen cases cover healthy smoke
and ownership, primary failures, cleanup-only failures, combined failures and
slower siblings. Existing ownership tests retain Firefox shutdown ordering.
The WebRTC instrumentation fixture now implements the real server close callback.

Commands: Python unittest discovery for `test_browser_cleanup.py` and
`test_ownership_browser.py`; `node --test scripts/reference/browser/webrtc_instrument.test.cjs`;
source and harness lint. These controls prove cleanup behavior, not live browser qualification.

## Outcome

State: findings-acted. No request failures were suppressed and no healthy receipt
schema changed. Existing workload and process watchdogs remain required when an
actual browser or socket never completes shutdown.
