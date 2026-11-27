# Native relay failure evidence

| Finding | Evidence | Action |
| --- | --- | --- |
| A failed room needs the same source identity checks as a successful room. | The provenance regression raised `FileNotFoundError` for `native-online.json` after a room failure. Changing the inputs during a live sweep also prevented a valid receipt. | Record selected and attempted rooms, input and export identities, and log hashes for either outcome. Recheck file identities across the final hash sweep. |
| The three observed relay expiries have different cutoffs. | #473 expired at frame 16 before warmup, #529 expired after all eight pages released their inputs, and #498 expired after the reporting peer published history. At the #498 expiry, the controller had received three of eight histories. | Keep the phase-specific issues and replay their own room profiles. Replace closed #526 with #529 in the plan. |
| Native inbox admission and protocol liveness are distinct observations. | The bridge records enqueue at `native_online_bridge.gd` and the pinned protocol updates `last_recv_time` after its connection and protocol-state checks. The earlier #529 archive has later server writes without a decoded browser arrival. | Use the exact transport stamp to join the independent observations. Keep timing in each clock domain and record missing coverage. |

The [transport note](../knowledge/transport-tooling.md) records the receipt
checks and the boundary of the native inbox observation.

State `findings-acted`.
