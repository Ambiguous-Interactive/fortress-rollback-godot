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
