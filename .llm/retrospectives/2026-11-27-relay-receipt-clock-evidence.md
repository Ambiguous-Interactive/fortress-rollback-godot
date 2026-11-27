# Relay receipt timing and expiry evidence

| Finding | Evidence | Action |
| --- | --- | --- |
| A delayed continuation can make a timely file publication appear late. | The clock control opens the matching generation at 99 ms and finishes reading at the 100 ms deadline. It reports `late_read` and the next call consumes the original pending generation. A separate control rejects selection at its deadline. | Use the opened generation and the original request interval. Compare server work measured before rename against the full controller request window. |
| Retained writes and browser observations answer different timing questions. | The proxy tests select the original packet by stamp and digest, preserve a later write after an epoch change, and partition page observations before and at or after expiry. An incomplete page originally threw `Cannot read properties of undefined`. The final test preserves partial coverage and refuses to pick between two anchor writes. | Keep the clock and exact link in the receipt. Report missing or ambiguous anchors and preserve the original failure. |
| A successful gameplay and Leave receipt can precede a failed server trace read. | The 4.7.2 Firefox replay on CPUs 0–2 recorded 40 matching rows and eight Leaves before `relay server receipt deadline`. The mixed rooms compared 44 and 40 rows on each Godot pin and completed every Leave. | Keep the trace deadline separate from native expiry and retain the failure log even after gameplay completes. |
| Dispatch evidence needs the application receipt that consumed it. | Both engine pins held the second leaver at boundary 8 or 40 and compared 42 canonical survivor rows. Mutating dispatch order or the applied freeze byte failed the validator on each actual receipt. | Bind the coordinator acknowledgement and the leaver's consumed release to the same session and operation. Verify capture beyond the second freeze. |

The [browser evidence guidance](../skills/testing/references/browser-integration.md)
now keeps the receipt timing and bounded archive rules beside the exact packet
joins. The [High Resolution Time specification](https://www.w3.org/TR/hr-time-3/#time-origin)
and [Node performance API](https://nodejs.org/api/perf_hooks.html#performancenow)
define the distinct page and controller time origins. The comparison uses
durations within each clock and only the causal bounds established by the
shared receipt generation.

The first Godot 4.3 comparison finished gameplay but rejected its receipt
with `native browser witness inputs changed during execution`. The frozen
worktree rerun produced an independently verified receipt. Existing
[infrastructure guidance](../skills/testing/references/infrastructure.md)
already requires that freeze.

State `findings-acted`.
