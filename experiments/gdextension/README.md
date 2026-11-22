# Fortress Rollback for GDScript

This experimental addon links Fortress revision `d124c89080004d96971a629bb0427056ee1805e3` to Godot through godot-rust 0.5.5.
The Rust crate owns sessions, packet encoding, prediction, correction and snapshot cells. GDScript owns the game state and simulation.
The GDScript-only addon in the main project has its own protocol and release contract. See the [experiment results](../../docs/experiments/upstream-binding.md).

## Install and use

Extract the archive for your editor architecture and export target into your Godot project. Restart the editor.
A Web archive includes the host editor library and the single-threaded Web side module.
Enable **Extensions Support** and turn off **Thread Support** in the Web export preset.
Game authors only need Godot and the archive.

Create a `FortressNativeSession` with `FortressNativeSession.new()`. For the network experiment, call `start(local_slot)` with slot 0 or 1.
The other participant runs the same pinned Fortress crate with input type `[u8; 4]`, zero input delay and the default prediction window.
The binding accepts exactly four input bytes per player. The sample game interprets them as a little-endian unsigned integer.

Each tick, feed datagrams from the other participant to `receive(packet)`, call `step(local_input, game)`, then deliver each member of `drain_packets()` to that peer.
Keep the same local input on a stalled frame. Drain packets while synchronizing and stalled, too.
Step returns 0 for a completed step, 1 for waiting, and -1 for an error. Discard the session on error.
`confirmed_frame()` reports the upstream confirmation frontier. The adapter bounds each packet queue at 256 entries.
It represents one known remote address. Authenticate and associate the sender in your transport.

The game implements three synchronous callbacks. Fulfill each before returning and avoid re-entering the session during a callback.

| Method on the game object | Contract |
| --- | --- |
| `save_state(frame: int) -> PackedByteArray` | Return complete deterministic state at the requested frame. Rust takes its own copy. |
| `load_state(frame: int, bytes: PackedByteArray) -> bool` | Restore the snapshot and check its frame. Return true on success. |
| `advance_game(bytes: PackedByteArray, statuses: PackedByteArray) -> bool` | Run one simulation frame in player order. Slot i occupies four bytes at offset 4i. Status 0 is confirmed, 1 predicted, 2 disconnected. |

For local sync tests call `start_sync(players)` and `step_sync(packed_inputs, game)`. The benchmark uses two and eight players with check distance two.
The [test game](project/driver.gd) demonstrates all three callbacks. Its HTTP connection carries test commands and datagrams to the loopback UDP bridge.
A live game supplies its own transport. The experiment does not implement SignalFish negotiation, replay migration, spectators or coordinated drop.

## Reproduce

From the repository root, install Python 3.12 or newer and Rust 1.99.1. This command fetches digest-checked source, editor and templates, builds both executables,
installs the addon archive in a fresh project, exports, runs both slot assignments and checks both failure controls.

```sh
python3 experiments/gdextension/platform_test.py 4.3 linux
python3 experiments/gdextension/platform_test.py 4.7.2 linux
```

Results, including `addon.zip`, `qualification.json` and the Linux `benchmark.json`, appear under `.cache/native-experiment/<version>/<target>/`.
Rust build artifacts share `.cache/reference/target/gdextension/`. Release builds and a normal Godot import each contribute to the first-run cost.
For Windows and macOS, run the corresponding target on a native host. The workflow also contains Android emulator and iOS Simulator jobs.
The Android job builds ARM64 and x86-64 libraries. The iOS job packages ARM64 device and ARM64 simulator slices. Device signing and store distribution are separate release work.

For Web, activate Emscripten 3.1.74, install nightly-2026-02-01 with `rust-src` and the `wasm32-unknown-emscripten` target,
and install Playwright 1.64.1 with its Linux browsers and dependencies. Set `FORTRESS_PLAYWRIGHT_PACKAGE` to the installed Playwright package.
Run the same command with `web` under `xvfb-run -a`. The [workflow](../../.github/workflows/gdextension-experiment.yml) gives the exact setup.

To repeat one exported run or isolate a control:

```sh
python3 experiments/gdextension/qualify.py \
  --export .cache/native-experiment/4.3/linux/witness \
  --peer .cache/reference/target/gdextension/release/reference-peer --slot 1
```

Add `--control restore` or `--control encoding` to inject a defect. A single control run exits unsuccessfully.
The matrix runner requires the specific diagnostic for each control.

The witness uses the default Godot logo from the 4.3 Android template. Copyright © 2017 Andrea Calabró. [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)
