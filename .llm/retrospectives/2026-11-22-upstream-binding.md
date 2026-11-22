# Qualifying upstream Fortress as a Godot extension

## Work under review

The experiment linked the pinned crate, exported a GDScript game and ran it against a separate stock UDP peer.
The new native dependency and multi-platform build warranted an adversarial review.

## Findings and actions

- A successful Cargo build can omit the Emscripten cdylib. Pin the nightly, check the actual module and load it in an exported game.
- The first headless import on Godot 4.7.2 crashed with the addon. Pre-registering the manifest in the test project allowed the actual export and match to run.
- The first encoding control failed on integer overflow in the validator. Apply the game's u32 arithmetic to expected state and require a distinct encoding diagnostic.
- Counting loads alone accepted a weak rollback witness. Require a backward restore and an input change during replay of the deliberately delayed frames.

The reproduction commands and evidence live with the [experiment report](../../docs/experiments/upstream-binding.md).
The [matrix](../../experiments/gdextension/matrix.py) enforces the negative controls for future runs.

## Prune ledger

The pure GDScript shipping contract still describes the existing addon. The experiment records its own qualification evidence.

## Outcome

findings-acted
