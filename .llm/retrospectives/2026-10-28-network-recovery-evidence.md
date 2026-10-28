# Retrospective: network recovery evidence

## Work under review

Session 106 addresses terminal mixed-path failures (#75), unequal exposed-history
donor recovery (#188), and exported spectator viewing (#245). The runtime fix,
source comparisons and browser witness receive separate fresh adversarial reviews.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A composed transport can hide a latched SDK failure behind successful relay service. | `signalfish_fallback.gd` omitted SDK_FAILURE from poll handling and checked only WRONG_STATE in direct status. Three new failure cases fail before repair; ERR_BUSY passes. | Propagate terminal direct status and poll errors. Extend the existing networking skill's composition paragraph. |
| Unequal public frontiers can be produced without editing session counters. | The actual Rust/Godot grouped witness advances one coordinator through its public request API, observing frontiers [4,5] and source retained floors [3,2]. | Extend the existing source comparison and validators; preserve independent original histories and explicit wire-parity limits. |

The exported viewer work reinforced existing source/tool-freeze and final-event-drain
rules. The first import attempt included extracted duplicate SDK sources; ignoring
those extraction roots fixed staging without weakening the addon/SDK inventory.
Fresh review checked the resolved Node invocation and Playwright/browser/template
inventories. Repeated final runs replace earlier receipts invalidated by edits.

Automatic PR review then found a missing construction boundary: a previously failed
adapter with reclaimed output could configure successfully, and an arriving relay
plan hid its error until polling. The new valid-ownership configuration regression
fails on the first candidate while the healthy busy control passes. Configuration
now rejects that adapter before taking ownership. A fresh delta review ran clean.
The existing networking guidance now names configuration alongside status/enqueue/poll.

Provisioning polls now wait briefly after not-ready responses, preserving existing
deadlines while reducing development control-service polling. The final browser
rerun exposed an expected HTTP 404 as a browser console error despite all 48
canonical comparisons passing. A table-driven red test proves all four pending
resources were counted as rejections. They now return authenticated HTTP 202;
unknown paths and denied capabilities retain their error responses. Browser
integration guidance records the distinction without suppressing real errors.
All four final browser cells and both native healthy cells pass after these changes. The earlier live ownership run correctly
rejected the changed source inventory; its partial rounds are not final evidence.

Later review found that the altered-state gate checked its expected error without
enforcing zero earlier acceptance/playback. It now checks the independent control
state before host termination and after HTTP shutdown, plus typed viewer observations.
The callback observer increments at entry so rejected calls cannot disappear;
its native regression is red before repair and green on both pins, with unchanged
canonical game bytes. Existing browser guidance now requires those independent
negative observations. Ownership inputs are disjoint from this fixture-only delta;
all four completed rounds still match every current source hash.

Final review identified missing browser request-failure events. A Node event-driven
regression is red without the handler and green with it; ordinary page/console
errors retain their existing behavior. Request failures are ignored only after
deliberate watchdog/finally teardown begins. Browser runtime cells are refreshed
for the observer change; no native or ownership input changed.
The process-level regression also executes the controller's real entry point with
a stub Chromium module. Its healthy control exits zero; an active request failure
is recorded and exits nonzero. Independent missing-wiring and missing-exit mutants
both fail the intended process-status assertion. This closes the helper-only
coverage gap without adding a production test flag.

## Verification

- Both pinned engines pass all 24 fallback/mixed cases, repeated in fresh processes.
- Both pinned engines pass eight source-comparison scenarios twice with 347 negative controls.
- Both engine pins pass actual exported Chromium viewing and altered initial-state rejection.
  Healthy viewers compare 48 canonical boundaries, pause with retained rows, catch up and finish cleanly.
- The unchanged busy control distinguishes retryable refusal from terminal SDK failure.
- Source-width and harness checks pass. Existing ownership inventory tests pass 46 cases;
  harness self-tests pass 161 cases.
- Local command outputs and source-bound receipts are recorded in the machine-local
  `progress/session-106-recovery.md` delivery log.

## Prune ledger

Updated the existing terminal-composition guidance instead of adding a duplicate
transport rule. Its prior lifetime fence remains explicit alongside SDK failures.
Existing source-comparison documentation retains physical donor eviction, broader
loss/reordering schedules and full protocol parity as unqualified work.

## Outcome

State: `findings-acted`. Broader physical/live recovery and exported host/seated
browser lifetimes remain in their existing issues.
