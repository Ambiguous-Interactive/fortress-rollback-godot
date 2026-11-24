# Native relay warmup receipt

## Work under review

[Issue #458](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/458)
tracks eight-player Firefox relay rooms. In hosted Godot 4.7.2 run
[45321948316](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45321948316),
all eight page traces reached their warmup gate. The controller timed out
waiting for its predicate. The witness now uses those checkpoints for the
warmup barrier in the traced relay cell.

## Findings

| Finding | Evidence |
| --- | --- |
| A redundant predicate RPC can lose a gate the controller already observed. | The seven-CPU exported baseline on 4.7.2 failed in warmup with `control withheld warmup predicate RPC` and eight gate cutoffs. The preload intercepted only the old frame-12 predicate call. |
| Receipt qualification needs both sides of the controller window. | The control counts a gate during the pending start acknowledgment and rejects one at the exact deadline. The late gate remains visible in the diagnostic trace. |
| Malformed diagnostics can mask useful earlier evidence. | Fresh review found that cutoff-only payloads could open the barrier and a null payload could displace a valid checkpoint. The control crosses invalid state, frame 11, malformed links and malformed ticks before the valid receipt. |
| Real native expiry can prevent the gate from being produced. | A three-CPU 4.7.2 baseline ended at frame 16 with frame 8 confirmed. One final read reported native disconnect and seven reported room membership or transport lifetime changes. [Issue #473](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/473) tracks the first expiry separately. |

## Actions and pruning

The [browser testing reference](../skills/testing/references/browser-integration.md)
now calls for reusing an existing one-time console checkpoint with the same
predicate, per-page coverage and deadline. The existing readiness predicate
RPC was removed from the traced relay cell. The
[Web room guide](../../docs/experiments/upstream-binding.md#playable-web-rooms)
documents the page cutoff and controller arrival clocks.

`python3 scripts/reference/test_browser_cleanup.py` reported `Ran 16 tests` and
`OK`. Disabling the exact deadline, confirmed-frame or link validation
each made the controller regression fail. `make test-reference` reported
`43 files, 0 failed`.

## Outcome

State `findings-acted`.

The exported `native_online_probe.py --browser-pair firefox --cell relay:8`
control printed `relay:8 passed` on both pins with the old predicate RPC
withheld. Each compared 40 confirmed input rows and canonical snapshots
and received eight warmup cutoffs, with at least 13 control round trips per
peer on 4.3 and six on 4.7.2. Both Firefox four-player and Chromium
eight-player controls passed on both pins. `make gate` reported
`{"passed": true}` for 869 cases in each of two runs.
