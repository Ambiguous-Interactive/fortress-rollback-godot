# Relay expiry and alternating browsers

| Finding | Evidence | Action |
| --- | --- | --- |
| A final page read can lose the queue and service interval from an expiry turn. | The original console receipt discarded all four fields in the regression. The controlled Godot 4.7.2 mixed-room expiry retained eight histories through frame 40, joined both packets through six stages, and preceded SDK removal by 134.353 ms. The Firefox warmup control retained its expiry receipt with no open gates and one complete quality-report join. | Capture service start, current and peak gaps, and pre-poll queue depth in the terminal checkpoint. Resolve its endpoint against the frozen roster. |
| Host-only ICE did not sustain an eight-player alternating room. | The historical hosted mixed runs and the bounded local Godot 4.3 repeat reached the setup deadline. The same local profile with a verified STUN response printed `4.3 clean passed in 63s`. | Use the existing STUN-only witness for the alternating profile. Keep the single-engine checks and run both Godot pins in Nightly. |
| Rollback preflight lost request attribution when a snapshot slot contained a stale frame tag. | The healthy control re-simulated. The corrupted control reported `HISTORY_UNAVAILABLE` with frame and kind both `-1`. The repair reported frame 0 and LOAD with zero new callbacks. Both Godot pins passed 26 focused cases in each fresh run. | Propagate frame and kind from the failed preflight. Exercise the public driver in the same fixture as the healthy correction. |

The [browser test guidance](../skills/testing/references/browser-integration.md)
records the service sampling boundary. The [plan](../../PLAN.md) keeps the
remaining Safari gate and drops the completed Linux WebKit task pointer.

State `findings-acted`.
