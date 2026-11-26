# Native Web qualification blockers

| Finding | Evidence | Action |
| --- | --- | --- |
| Browser package setup could consume the whole Web job. | Hosted job 139745683423 ran until the 70-minute deadline inside APT. Playwright 1.64.1 produced identical combined and split dry-run inventories. The original split moved TURN setup ahead of the generic export, which the adversarial pass caught. | Bound dependency acquisition and browser download separately. Keep TURN and xdotool setup after the generic exported controls. |
| Receiver acceptance can move during same-link pressure. | SDK work from before the gate remained pending. Both real Chromium rooms retained the original six-stage joins after 520 newer packets per family when the exact pin was taken at gate resume. Gate duration was 471.150 and 567.025 ms. | Freeze the pin at gate resume and check that its raw arrival predates gate entry. Keep ordinary trace output at 128. |
| Native pending input statistics can be unavailable at early ticks. | `network_stats` requires prior timing activity. The regression test can put real inputs in the native pending queue before that metric is available. | Sample `peer_metrics().pending_output_len` with direct receipt and fold bounds. Keep the sample optional for older addon binaries. |

The [browser integration guide](../skills/testing/references/browser-integration.md)
now describes gate-resume capture and bounded hosted setup. The previous advice
to use a gate-entry stamp for every pressure control applies to quiet-link cuts.

State `findings-acted`.
