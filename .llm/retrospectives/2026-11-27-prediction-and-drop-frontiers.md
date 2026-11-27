# Prediction stalls and drop frontiers

| Finding | Evidence | Action |
| --- | --- | --- |
| The first call at a prediction cap can stage input. | Both pinned engines and Rust emitted on the first stalled call at windows 5–7. Identical retries at operations 6, 7 and 8 held their frame and emitted no new packet. A coherently advanced trace after frame-zero confirmation failed with `error mismatch`. | Record the two calls and distinguish earlier rollback callbacks from forward progress in the [oracle guidance](../skills/testing/references/oracle-validation.md). |
| An agreed freeze alone cannot show that both opening frontiers survived. | The initial validator accepted ten altered or missing opening fields. The final Chromium witness measured each survivor opening at frame 3, restored original frames 4–6, and froze at 6 on both pins. It rejected removed or raised frontiers from both actual receipts. | Bind the opening event to the same target and its later certified freeze. Keep the unequal live case under [#188](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/188). |
| The observed serial schedule and the overlap control qualify different ordering boundaries. | Chromium ran seven coordinated-drop cells on each pin and printed `"passed": true` and `"runs": 14`. The failed canonical controls reported `peer_drop_canonical_8`. The merged overlap evidence includes Firefox and the named missing-COMMIT control. | Replace the completed live checklist pointer in the plan with [the serial timing edges](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/531). |

The focused oracle suite printed `Parallel unittest: 19 files, 0 failed`.
Both pins matched pinned Rust for the new windows in fresh processes.
The drop-history launcher's first local receipt was rejected when the checkout
changed during execution. The rerun needs a frozen source inventory.

State `findings-acted`.
