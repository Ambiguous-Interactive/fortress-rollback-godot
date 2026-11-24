# Native browser input hold

## Work under review

The eight-player Firefox witness reached its prediction stall in hosted
run 45262075481, then seven peers reached the input cap before release.
Issue #467 tracks that boundary. The witness now records page readiness
and starts the existing FIFO drain in the stalled snapshot call.

## Findings

| Finding | Evidence |
| --- | --- |
| The controller can observe a ready peer late. | Cold review found that the first implementation awaited every arm response before starting readiness checks. The final page call arms and starts observation together. The socket control checks that later polls preserve the first mark. |
| The stalled snapshot can change while an asynchronous drain runs. | The browser cleanup control mutates nested state during release and verifies the captured state stays fixed. It also rejects a failed release and checks that its pre-release snapshot remains available. |
| Page lifecycle commands can delay correction even after the FIFO drains. | The reviewed implementation awaited Playwright handle disposal before checking the shared correction deadline. The final page readiness call returns only the value and owns no remote handle. |
| A failed warmup gives no release timing evidence. | The three-CPU Godot 4.7.2 Firefox two-call control timed out in warmup with two native disconnects and no arm marks. The hold path was never reached. |

## Actions and pruning

The [browser integration reference](../skills/testing/references/browser-integration.md)
replaces its general pre-release snapshot advice with the measured page and
controller boundaries. The [Web room guide](../../docs/experiments/upstream-binding.md#playable-web-rooms)
names the fields and their clock domains. Keep warmup and correction failures
with their existing issues [#458](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/458)
and [#460](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/460).

The focused command
`python3 -m unittest discover -s scripts/reference -p test_browser_cleanup.py`
reported `Ran 14 tests` and `OK`. The two-call control failed the
same-call check before it could claim a release.

## Outcome

State `findings-acted`. Existing packet and correction bounds still apply.
