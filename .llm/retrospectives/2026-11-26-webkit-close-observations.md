# WebKit close observations

| Finding | Evidence | Action |
| --- | --- | --- |
| Final page reads can lose the close boundary. | Hosted run 45715541100 matched 40 histories before all eight final reads timed out. Its tagged send interval ranged from −18,002 to 13,445 µs. | Publish the close stages when they occur and keep their page and controller times. |
| A close can precede complete ICE signaling. | The close fixture calls a channel with a missing remote credential at 50,000 µs and calls it again after signaling. The retained observation has the original time and a null remote credential. | Keep raw observations with partial credentials and require both credentials to join. Refresh credentials on live status reads. |
| A route and an attempt answer different questions. | The close fixture rejects a channel-only diagnostic and a duplicate reciprocal route. With attempt 279 it reports an interval from 1,999 to 2,399 µs against the connection close invocation. | Arm send tagging before planned physical closes. Keep invocation intervals diagnostic and require the existing completed-close proof for acceptance. |

The [browser integration guide](../skills/testing/references/browser-integration.md)
now points to the close receipt contract. Its earlier requirement to retain
clock samples applies to both passing and failing rooms. A later complete
proof round still owns the room verdict.

State `findings-acted`.

The replay download controls run at the launcher boundary. The real descendant
test verifies the cleanup log, the child's terminal state and the absence of
stale success. The interpreter test runs a disposable Python copy and replaces
its executable after the launcher freezes its digest. The old interpreter
completes the fixture. The changed executable prevents receipt publication.
The two-control command reported `Ran 2 tests` and `OK`. The
[ownership guide](../../docs/experiments/buffer-ownership.md#received-browser-replay-downloads)
now records these controls and replaces the stale open-control note.

A stock Firefox room on Godot 4.7.2 reached the release boundary with
983–1,006 held inputs per page. All eight pages then reached 1,024.
The [stock run](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45725387847)
measured 8.874–8.881 seconds from controller dispatch to page entry.
The receive listener used to decode two UUID strings per valid foreign
broadcast. Eight alternating Node samples exercised 73,500 receives and
10,500 addressed packets each. The upper median fell from 218.25 ms to
87.65 ms. The test still rejects a malformed foreign native header and
counts both valid broadcasts. The
[migration guide](../../docs/native-backend-migration.md#session-boundary)
records that distinction. Hosted hold qualification remains open.

The full reference run caught a reaping assertion immediately after SIGKILL.
The ownership receipt named the escaped child and the launch rejected it,
but its original PID still appeared live in `/proc` on that scheduler turn.
Poll the same PID and start time through a bounded deadline before requiring
a terminal state. Keep the exact rejection and absent receipt checks.
