# Relay retention through link pressure

| Finding | Evidence | Action |
| --- | --- | --- |
| A global trace can lose a quiet link while the room continues playing. | The browser control failed with `input tail of inactive link was evicted by healthy links`. The pinned Rust control retained sequence 99 where it expected the quiet link's sequence 31. | Bound records per directed link, packet family and stage. Keep aggregate occurrence order and count omissions. |
| A successful snapshot query can still be stale. | The request control publishes replies from another generation before the matching one. A delayed rename also let two callers advance the generation before the first resumed. | Keep one caller and one pending generation. Preserve that generation when observation times out. |
| The inputs in a receipt can differ from the inputs a build used. | A test changes the patch and module during application and restores them before the final fingerprint. The fixed build still consumes the original bytes. | Read, hash and consume the same bytes. Verify the manifest and both trace sources in the browser witness. |
| Arrival volume cannot prove that the two intended packets are held. | The new control failed when one target and unrelated arrivals released the FIFO. It also exercises duplicate stamps and a second socket. | Check distinct stamps on the original socket. Freeze the native receipt with the acceptance check. |
| A full snapshot at the start of a timed pressure phase can consume its budget. | The first traced Godot 4.3 run reported `relay server receipt deadline` with a 4.7 MiB snapshot. | Bracket the mute with physical send ordinals. Read the browser's exact frontier before pressure and collect large receipts after release. |

`python3 -m unittest scripts.reference.test_browser_cleanup` ran 30 tests.
`python3 -m unittest discover -s scripts/reference -p test_trace_server_provenance.py`
ran 4 tests. Both reported `OK`. The pinned server's
`cargo test --offline --locked --no-default-features --lib relay_packet_trace::tests`
reported `2 passed; 0 failed`.

On Godot 4.7.2, the ordinary Firefox trace first completed gameplay and
then exceeded the receipt deadline. A paired Firefox 157 benchmark over
7,504 observations reported 15,008 versus 7,504 digest calls and median
freeze times of 183 ms and 120 ms. The optimized real room printed
`relay:8 passed`, collected all eight receipts, and matched 40 frames.

The [browser integration guide](../skills/testing/references/browser-integration.md)
now specifies the binding, pending request, and retention rules. It replaces
the generic hold rule with an exact FIFO and stamp check. Historical failure
receipts still describe the original aggregate rings.

State `findings-acted`.
