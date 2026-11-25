# Relay readiness and hint selection

The browser witness needed a readiness sample before terminal cleanup.
A separate hint refresh expanded the unit wave to the full suite inventory.

| Finding | Evidence | Action |
| --- | --- | --- |
| A periodic checkpoint can miss a readiness change before expiry. | The browser control changed readiness at 999 ms and failed at 1,000 ms. The controller retained 100 ms instead of the expected 1,099 ms. | Publish on condition changes and retain waiting and terminal samples independently. |
| Continuous traffic can evict an idle link's last report or reply. | After 256 receives on one link, the test could no longer find the other link's last reply. The per-link record retains that reply. | Bound the latest traffic by the frozen roster, direction and kind. Keep the event history for separate correlation. |
| Count bounds alone can retain extra or inconsistent fields. | The readiness control submits a duplicate packet sample, an inconsistent pending reply and a future packet timestamp. It also supplies an extra field on a valid sample. | Reject the inconsistent observations and store only validated traffic fields. |
| A host-only archive can trigger the full Godot wave. | The selector regression returned `unknown_input` for the hint alone and alongside a gameplay file. The passing control selects zero suites for the hint and preserves the gameplay selection. A neighboring unknown archive still selects all suites. | Classify the exact archive path and leave dependency discovery and Gate tooling controls in place. |

The [browser integration guidance](../skills/testing/references/browser-integration.md)
extends its existing readiness procedure. Its traffic observations retain their
sample time. Native inbox receipts still establish packet acceptance. No other
guidance for this phase became obsolete.

The latest grouped baseline, run 45533473395, took 155.83 runner-minutes.
Its slowest oracle comparison was lane 2 at 203 seconds on Godot 4.7.2.
The lane 2 wrap launcher took 191.5 seconds and includes the lifecycle family.
The preceding group took 163.45 runner-minutes and its lane 1 took 392 seconds.
The grouping question remains in #479 pending a controlled comparison.

State `findings-acted`.
