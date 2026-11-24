# Native browser departure receipts

[Issue #475](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/475)
tracks a Firefox relay room that matched 40 confirmed frames before a
controller timeout. The prior log showed leave command 18, code zero and an
offline departing page even though the controller's polling wait expired.

| Finding | Evidence | Durable action |
| --- | --- | --- |
| A browser command and its completion event can settle independently. | The late-publication test failed with `Cannot read properties of undefined (reading 'code')` when dispatch rejected before receipt. After settling both operations, `python3 scripts/reference/test_browser_cleanup.py` reported `Ran 17 tests` and `OK`. | The [browser integration skill reference](../skills/testing/references/browser-integration.md) records how to correlate the receipt, retain it after rejection and require the test to finish. |
| Controller receipt and page execution need separate clocks. | The initial exported Firefox 4.3 eight-player room recorded about 2.08 seconds from dispatch to controller receipt and 1.2 ms from page entry to publication for command 18. The launcher invalidated its overall receipt after the runner was edited during execution. | The [browser room guide](../../docs/experiments/upstream-binding.md#playable-web-rooms) identifies the timestamp pairs for each interval. |

The witness uses the correlated event where the old controller polled for the
departure acknowledgment. The separate teardown check still requires offline
pages, terminated survivors and closed sockets and channels. Existing browser
evidence guidance now covers the dispatch-rejection race at its source.

## Exported acceptance

On both pinned Godot engines, `native_online_probe.py --browser-pair firefox
--cell relay:4 --cell relay:8` printed `relay:4 passed` and `relay:8 passed`.
Chromium printed `relay:8 passed` on both pins. Each room matched 40 confirmed
input rows and snapshots, verified every leave receipt and passed teardown.
The Firefox eight-player departure took 9.89 and 9.38 seconds from dispatch to
receipt. Page entry to publication took 1.72 and 1.16 ms respectively. Bounded
host warmup and correction still belong to [issue #458](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/458).

State `findings-acted`.
