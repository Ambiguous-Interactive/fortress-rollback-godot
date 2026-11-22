# Running upstream Fortress from an exported GDScript game

Prefer a thin GDExtension for projects that require upstream fidelity. The experiment demonstrated a stock Rust peer and an exported GDScript peer
completing the same corrected history. Keep the current addon available for its existing API, Godot protocol, recorded games and transport integrations.
Adopting a new default backend requires a separate migration decision. [Binding source, installation and reproduction](../../experiments/gdextension/README.md)

## Observations

On Linux ARM64, Godot 4.3 and 4.7.2 release exports completed the same mixed-peer match natively and in Chromium 156, Firefox 157 and Playwright WebKit build 2370.
The Web runs used single-threaded extension-enabled templates. The browser and Rust process exchanged actual upstream encoded messages over a local HTTP-to-UDP test bridge.
These runs establish the session, codec and callback boundary. Internet matchmaking and live WebRTC require their own tests.

For each engine and runtime the matrix swapped player slots, withheld Rust packets while the Godot game advanced through frames 8–11,
dropped one datagram and reversed the remaining burst. The game observed a backward load and a changed input during re-simulation.
Both peers matched 40 confirmed rows against a closed-form expectation. Their independently saved state at frame 40 was `2800000074360000a8390000`.
Deliberately corrupting a restored accumulator failed at observed frame 13. Reversing local input bytes failed the row comparison at frame 0.
Removing the editor library before startup gave diagnostic exit 23. Restoring it registered the native class.

The Linux ARM64 shared library measured approximately 2.56 MB and the Web side module 1.22 MB, excluding Godot.
Compressed addon archives measured about 0.79 MB for Linux and 1.13 MB for Linux editor plus Web.
Hosted runs passed the same exported match and both failure controls on Linux x86-64, Windows x86-64, and Apple Silicon macOS on both Godot pins.
The macOS addon contains ARM64 and x86-64 slices. Hosted Web passed on Chromium, Firefox, and WebKit on both pins.
Android 4.3 passed on an x86-64 emulator. The signed APKs include ARM64 and x86-64 libraries.
The Android 4.7.2 job installed and started the APK, then stopped reporting after the first HTTP request.
The iOS addon contains ARM64 device and simulator slices. The stock Godot simulator archive contains x86-64 objects, so the current CI build
compiles an ARM64 engine from each pinned revision and supplies that simulator library to the exported Xcode project.
[Hosted qualification and artifacts](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/44999235188)

## Performance

Headless Linux ARM64 measurements used the same four-byte inputs, 4096-byte snapshots and two-frame forced rewind for each backend.
Each cell below contains p50 / p99 / worst rollback step in microseconds, from 256 steps in each of two fresh processes.
The test compares actual ordered save/load/advance callbacks against standalone Fortress and checks all 4096 final bytes against an independent formula.
Each process recorded 253 rewind steps. Rendering, network transport and HTTP orchestration are outside this timed section.

| Godot | Players | Standalone Rust | Rust binding + GDScript | Existing GDScript session |
| --- | ---: | ---: | ---: | ---: |
| 4.3 | 2 | 0.79 / 3.96 / 9.25 | 6 / 41 / 52 | 115 / 158 / 279 |
| 4.3 | 8 | 0.96 / 5.79 / 8.58 | 9 / 19 / 30 | 200 / 254 / 321 |
| 4.7.2 | 2 | 0.79 / 6.13 / 13.75 | 5 / 9 / 28 | 81 / 104 / 138 |
| 4.7.2 | 8 | 1.00 / 4.08 / 8.83 | 8 / 17 / 26 | 159 / 224 / 307 |

Mean instrumented snapshot copy time for these runs ranged from 0.066 to 0.121 microseconds.
In GDScript this measures the game's explicit duplication inside the callback at microsecond clock resolution. Full step timing includes the binding's additional copies.
The port validates extra lifecycle and storage contracts, and the fixture is a small integer game. These numbers estimate this workload only.
No target game or frame budget was supplied. [Benchmark and equality checks](../../experiments/gdextension/benchmark.py)

## Distribution findings

Godot 4.7.2 aborted at shutdown during first headless import with the extension on this machine.
An empty project without the extension exited cleanly, and a second import with its extension list present exited cleanly.
The export harness explicitly registers the installed manifest in the temporary project's extension list before the first import.
This also lets Godot 4.3 resolve the native class during its first script scan. The automated export therefore includes one headless setup step.
Other maintainers have reported a similar first-import failure. [Godot issue 125063](https://github.com/godotengine/godot/issues/125063)

An unpinned Rust nightly rejected the Emscripten exception flag. With the February nightly a build initially exited successfully while dropping the cdylib.
The Web build now targets a position-independent dynamic side module, checks the dependency tree and requires a Wasm artifact before exporting.
Both pins loaded the resulting module in a browser. The maintenance cost is a native toolchain and a runtime test per target.
[Web build](../../experiments/gdextension/build_web.sh) · [Upstream Fortress Web guide](https://wallstop.github.io/fortress-rollback/user-guide/)
