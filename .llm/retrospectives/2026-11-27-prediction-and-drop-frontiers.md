# Prediction stalls and drop frontiers

| Finding | Evidence | Action |
| --- | --- | --- |
| The first call at a prediction cap can stage input. | Both pinned engines and Rust emitted on the first stalled call at windows 5–7. Identical retries at operations 6, 7 and 8 held their frame and emitted no new packet. A coherently advanced trace after frame-zero confirmation failed with `error mismatch`. | Record the two calls and distinguish earlier rollback callbacks from forward progress in the [oracle guidance](../skills/testing/references/oracle-validation.md). |
| An agreed freeze alone cannot show that both opening frontiers survived. | The initial validator accepted ten altered or missing opening fields. The final Chromium witness measured each survivor opening at frame 3, restored original frames 4–6, and froze at 6 on both pins. It rejected removed or raised frontiers from both actual receipts. | Bind the opening event to the same target and its later certified freeze. Keep the unequal live case under [#188](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/188). |
| The observed serial schedule and the overlap control qualify different ordering boundaries. | Chromium ran seven coordinated-drop cells on each pin and printed `"passed": true` and `"runs": 14`. The failed canonical controls reported `peer_drop_canonical_8`. The merged overlap evidence includes Firefox and the named missing-COMMIT control. | Replace the completed live checklist pointer in the plan with [the serial timing edges](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/531). |
| Trace export can fail after gameplay and Leave complete. | Both 4.3 rooms on CPUs 0–2 captured 40 rows and clean Leave for eight pages. Firefox hit its page read deadline and Chromium hit its server response deadline. A one-core Firefox control took 7,444 ms with page hashing and 2,719 ms with controller hashing while preserving receipt fields. | Freeze retained bytes before hashing and check the controller deadline after materialization. Keep [server timing](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/533) and the gameplay expiry issues separate. |

The focused oracle suite printed `Parallel unittest: 19 files, 0 failed`.
Both pins matched pinned Rust for the new windows in fresh processes.
The drop-history launcher's first local receipt was rejected when the checkout
changed during execution. The frozen rerun passed. Both pins report 1,137
negative controls and equal fresh-process repeats.

State `findings-acted`.
