# Native hold milestones and shard fixture isolation

| Finding | Evidence | Durable action |
| --- | --- | --- |
| An independent request can add scheduling delay to a browser checkpoint. | The three-CPU Firefox 4.7.2 relay room reached release 6.7–7.0 seconds after local readiness on main and 14.1–14.3 seconds with a same-origin HTTP barrier. Console readiness preceded the HTTP request by 7.0–7.1 seconds. Both runs hit the input cap. | Keep the existing release command. The [browser witness guidance](../skills/testing/references/browser-integration.md) now calls for independent readiness marks and separates active queue depth from cumulative traffic at the cap. |
| A scripted engine does not need a full project to verify shard receipts. | The old focused control took 43.924 seconds on the workspace mount. The authored fixture took 1.422 seconds on the mount and 0.381 seconds on local temporary storage. The new fixture checks two distinct process results and rejects an omitted case in one or both processes. | Run the real launcher over the committed minimal project. Keep the unselected suites in the snapshot so selection still has to exclude them. |

## Verification

`python3 scripts/reference/test_browser_cleanup.py` reported
`Ran 18 tests ... OK`. The FIFO fixture reported 1,024 cumulative packets,
1,008 queued and 16 already released before rejecting further input.
`python3 -m unittest discover -s scripts/reference -p test_godot_runner.py -k verified_full_shard -v`
reported `OK` with the default temporary storage and with `TMPDIR` on the
workspace mount. The existing launcher and its source and receipt checks
run in both cases.

On the three-CPU Firefox 4.3 control, the exported witness printed
`relay:4 passed` after comparing 40 confirmed frames and completing teardown.
The eight-player room reached every warmup gate. Each peer's first matched
control reply arrived 7.6–7.9 seconds after its first held input. All eight
drains completed and correction checkpoints arrived, but `corrected history`
timed out before the final comparison. The phase remains open in #467.

State `findings-acted`.
