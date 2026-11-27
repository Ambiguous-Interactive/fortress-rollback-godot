# Native room source identity

| Finding | Evidence | Action |
| --- | --- | --- |
| An archive cache can contain generated files. | A fresh extraction of the reviewed SHA-256 archive contained identical archived file bytes. The existing cache also contained `target/CACHEDIR.TAG` and its directory. | Derive the expected tree digest from a clean extraction. Put Rust targets in the shared build cache and keep incidental output out of verified source roots. |
| The wire version and native profile can disagree when supplied separately. | The cold review could pair candidate admission with the version-2 observer. An empty expected profile could also equal the missing-addon value. | Make a full source revision select both values. Check the installed profile before connecting and have the traced server derive its filter from the same revision. |
| A directory name and protocol byte can survive source changes. | Adding a comment to the candidate's `src/lib.rs` leaves the name and protocol constant intact. The source verifier rejected the changed archive tree. | Hash archived paths and file contents before building the linked addon. |
| Archive verification can be skipped by Cargo's timestamp cache. | A cached build can keep the original verification output when a file changes and its modification time is restored. A missing build-script stamp caused Cargo 1.99.1 to run the verifier again. | Run byte verification for every Cargo invocation that would reuse the addon. |
| A failed parallel build can cache an altered dependency. | The review reproduced a failed build that cached the dependency first. After restoring the source and its old timestamp, the next executable still returned the altered value. | Check the verified source before starting Cargo and refresh the Fortress dependency in the export build. |
| A successful game can lack its traced wire receipts. | The traced version-6 room matched 40 rows, then reported `missing relay send sync`. The receipt decoder still required version 2. | Pass the selected revision through warmup, hold, and expiry observers as well as the main gameplay check. |

The reviewed browser accepted its historical packet and rejected the candidate
byte. The candidate hit that same guard during warmup on both Godot pins.
The [room probe](../../experiments/gdextension/README.md#reproduce) now checks
the selected installed profile and passes one revision through both raw observers.

State `findings-acted`.
