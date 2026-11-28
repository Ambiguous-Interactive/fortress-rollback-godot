# Retrospective — 2026-11-28 prediction and browser coverage

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| The browser launcher and its receipt validator both restricted asymmetric recording to Chromium. | The old Firefox invocation exited 2. The revised launcher ran three rooms on each pin for each of the three browser pairs, with 257 rows per completed playback. Completed recording bytes matched across the pairs. | The validator checks browser assignment by endpoint. The mixed receipt control swaps both browser names and expects an inventory error. |
| A workflow test supplied browser and engine values separately from the actual matrix. | The first Nightly selection check failed with `0 != 1` on both mixed lanes. Review showed the repaired shell test could still pass after removal of a configured engine. | The test reads the configured axes, checks the pair binding, and executes each selected job branch. All 21 workflow tier tests passed. |
| The installed native driver returned status zero for a retained sample after a real prediction stall. | Both pinned editors returned `code=0 status=0 expected=1 frame=13` on the original addon. The repaired addon passed nine layouts on each pin, including corrective callback termination and the wrong-sample control. Only the GDScript adapter differed between the two addon archives. | The existing package qualifier checks the retained sample status. The [oracle guidance](../skills/testing/references/oracle-validation.md) records the full read contract. |
| A scenario named for an eight-frame stall ended its held phase before the exact cap. | The old scenario failed with `prediction witness missed last admissible advance`. The selected Fortress observer and both Godot pins then reported the admitted step, blocked step, silent retry and corrected playback for every window from two through eight. | The oracle checks the complete family and verifies original frame-zero delivery, ordered repair and resumed progress. |
| A proxy write may appear in the final receipt after a page observer has sealed its snapshot. | The future-inlet control returned `unobserved` on the original join. The repaired join reports `outside_capture` at and after the cutoff. | The [browser guidance](../skills/testing/references/browser-integration.md) records the scope of sealed captures. |

## Outcome

State is `findings-acted`. The browser guide now names the tested
Firefox profiles in place of the Chromium-only restriction. WebKit
recording and the natural relay-expiry phases retain separate acceptance.
[WebKit follow-up](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/563)
