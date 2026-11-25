# Relay broadcast cost and WebKit close intervals

| Finding | Evidence | Action |
| --- | --- | --- |
| The relay formatted both UUIDs and copied the payload for unrelated broadcasts. | The Godot signal-path probe counted 364,000 ignored broadcasts and queued zero at each revision. The median for 120,000 deliveries fell from 1,399,164 to 473,508 µs on 4.7.2 and from 2,931,449 to 745,966 µs on 4.3. | Compare against the frozen roster's wire UUIDs and copy only addressed payloads after capacity checks. Keep refusal order in the relay tests. |
| A lower timing bound alone cannot distinguish a short gap from uncertainty. | A replay of six hash-verified hosted WebKit receipts kept 364 accepted proofs and seven unresolved tags. Each unresolved interval spans the 2 ms threshold. | Retain both interval endpoints and the successful rooms' calibration samples. Compare both receipt outcomes before changing proof collection. |
| A close witness can finish the physical work before its controller runs out of time. | Group 45546973687 failed at the absolute departure deadline with all 18 channels and 12 tracked connections closed. Its visible stages included survivor agreement and one advance after the pause. An earlier verified archive showed the same deadline with every page still at the pause. | Combine the observations and actions that belong to one page. Preserve the cross-page pause and close barriers and record where the controller times out. |
| Source mutation invalidates a long-running witness even after its gameplay checks pass. | The mixed 4.7.2 baseline printed both room passes and then reported `native browser witness inputs changed during execution`. The first Gate attempt reported `source_changed_during_capture`. | Use an isolated worktree for concurrent code changes and require the final frozen receipt. |

The transport skill now ties broadcast performance to refusal accounting. The
browsers skill records how to interpret clock intervals. The plan names the
unqualified pre-departure lifetime boundary alongside warmup and correction.

The first 4.7.2 candidate produced a frozen receipt with 40 matching rows and
snapshots in the mixed four- and eight-player rooms and no native expiry.
The comparison is a local witness. The hosted Firefox and WebKit profiles
still own their release acceptance.

State `findings-acted`.
