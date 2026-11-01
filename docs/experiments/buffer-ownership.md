# Packed buffers and bounded snapshot ownership

R2 research for [issue 23](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/23).
The hypothesis is that explicit byte copying and operation-scoped checked views
can isolate caller-owned buffers from bounded, protected snapshot history.
The [tested representation](../../tests/determinism/ownership_slots.gd) is a
research fixture, not a shipped session API. The executable
[ownership suite](../../tests/determinism/test_buffer_ownership.gd) covers
the engine boundaries and representation together.

## Contract and source

The [ownership contract](../contracts.md#input-and-snapshot-ownership) requires
copied input, library-owned history, exact lengths, frame/generation tags and
expired retained views. The pinned upstream reference is Fortress
`f13cd5c0f2815926785a395947e18da0dbea0dd8`, particularly
[`SavedFrame` and save/load](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sync_layer/mod.rs).
The GDScript view lifetime and checked byte representation are deliberate port
choices; the experiment does not claim Rust exposes the same API.

## Reproduction and meaningful negative control

From the repository root, run:

```sh
python3 scripts/reference/ownership_probes.py --offline --web
xvfb-run -a python3 scripts/reference/ownership_probes.py --offline --web --browser firefox
```

Omit `--offline` to fetch missing digest-pinned artifacts. Pinned Playwright must
already be installed using the baseline browser setup. The runner constructs
isolated temporary projects, uses both pinned editors and release Web templates,
and drives the same seed-1701 scenarios twice in-process, natively and in
the selected Chromium or Firefox browser. Chromium remains the default. Firefox
requires Ubuntu 24.04, Xvfb and xdotool, and runs a visible owned window with
`webgl.force-enabled=true`, `webgl.disabled=false` and
`toolkit.shutdown.fastShutdownStage=0`. It uses the existing
digest-pinned Firefox archive in an installation separate from the transport
witness. The browser name and exact version must match the selected pin.
The runner rejects process failures, engine errors, incomplete inventories,
repeat divergence and native/Web differences. The runner also includes the R1
integer/encoding suite; its evidence is recorded separately. Godot excludes
hidden `.llm` directories from exports, so the checksum sample is copied byte
for byte to a visible test resource and only its preload path is adapted in
both native and browser temporary projects.

Before each unmodified run, the tool intentionally replaces copied input history
with `var history: PackedByteArray = caller`. After the caller fills its buffer
with 9, both repetitions must report first divergence at frame 0, byte 0:
expected `0100`, actual `0909`, under the two labels for stored-input ownership
and callback-copy isolation. Native must exit 1; exported release assertions
must report those exact failures. Other failures invalidate the control.
The unmodified suite then passes with stored input `0100`.

An additional nested-object retention control replaced the decoded new `State`
with the original retained `state` object: replace both the constructor and
`decoded_state.value = restored[0]` assignment with
`var decoded_state: State = state`. Running the native 4.3 suite with
`--category determinism --filter snapshot_wraps` exited 1 and reported
`nested state restored from A after wraps`: expected 1, actual 9, in both
repetitions. The original serialization/decoding code was then restored. Raw
evidence is `.cache/reference/results/r2-nested-retention-red.log`.

The success receipt is `.cache/reference/results/ownership.json`; raw logs are
`ownership-<engine>-<negative|positive>-native-<suite>.log` and
`ownership-<engine>-<negative|positive>-browser-<batch>.log` beside it.
Native suites run in separate processes with a 180-second watchdog; Web pages
run groups of at most four Chromium suites or one Firefox suite with the same
180-second page watchdog.
Firefox runs each `test_driver_peer_parity` case in its own page. Each page
retains both repetitions. The launcher uses native case order, reassembles the
complete suite, and requires exact equality with the full native suite result.
Each browser launcher retains its 240-second process budget. Every case still
runs twice in-process. Complete batch inventories and exact metadata/types are
checked before the full native/Web results are compared; missing or duplicate
batches cannot qualify. Receipts declare the selected engine versions.
The default command runs both pins;
`--version 4.3` or `--version 4.7.2` runs both control rounds for one pin.
CI keeps both Chromium jobs and runs each Firefox pin/control phase in its own
job under the existing 30-minute budget. Both Firefox phases are required on each pin. Each selection runs the same complete case
inventory, native comparison and negative controls; it does not filter replay,
driver or spectator coverage. Firefox output additionally records its WebGL
preferences and checked window geometry.
Use `--phase negative` or `--phase positive` only for an explicit partition.
The receipt declares `phases_requested` and covers only its requested pins and
phases. A single-phase receipt never establishes complete qualification; both
phases must pass for every engine. Omitting `--phase` retains both phases.
Firefox CI on both engine pins also selects `--suite-part 1` or `--suite-part 2` within
each phase to fit the same 30-minute job cap. Parts alternate the sorted suite
inventory and repeat the ownership-control suite in both parts. Their union
covers all 67 suites and 426 cases; only the four control cases overlap.
Every selected case still runs twice, with exact native/Web comparison.
Receipts declare `suite_part_requested` and the exact `suites_requested`
inventory. Both parts and both phases must pass for full qualification.
Omitting `--suite-part` keeps the complete inventory.
Owned browser contexts close before their parent process. Full Firefox shutdown
also runs the destructor that removes late updater locks; exit code zero alone
does not prove cleanup. The [paired shutdown control](firefox-shutdown.md)
exercises late lock acquisition with the original inventory guard.
Runtime hashes still reject remaining installation changes. CI retains the last Firefox process lifecycle
trace in `ownership-firefox-process.log` for exit-code and signal diagnosis.
Receipts include the pin-manifest hash and executable source hashes. A fresh run removes
its previous receipt first, so an interrupted or failed attempt cannot preserve
an old success. The historical baseline before these probes was
`97c0d5bfef7eb5f746eae7bb51e6e573ff7e5e04`; source hashes identify this experiment.
Receipts also bind all files in the selected browser installation, the imported
Playwright packages, Node and each executed Web export. These inventories must
remain unchanged through completion and are checked around every browser batch.
The extracted Godot executable, installed Web templates and staged project inputs
are frozen and checked around their applicable commands. Editor import may add
paired metadata; the mutable `.godot` cache stays outside the authored inventory.
Unused npm command links are outside the imported packages; symlinks within any
inventoried runtime remain rejected.

## Observed engine boundaries

The completed local matrix on Linux arm64 passed with
Godot `4.3.stable.official.77dcf97d8` and
`4.7.2.stable.official.ed1daf0bf`, each natively and in Chromium
`141.0.7390.37` release Web exports. All four R2 cases passed 74 assertions per
repetition; the combined R1/R2 matrix passed 520 assertions per repetition
across eight cases. Each native result matched its Web result exactly, including
the deliberately failing alias controls. All receipt source hashes matched
the files at verification time.


| Boundary | Observation on Godot 4.3 and 4.7.2 |
| --- | --- |
| PackedByteArray assignment / parameter | Mutation changes the original; treat as shared mutable bytes |
| PackedByteArray `duplicate()` | Mutation does not change the original |
| Typed `Array[int]` assignment | Mutation changes the original |
| Typed array `duplicate()` with primitive elements | Mutation does not change the original |
| Typed `Array[RefCounted]` deep duplication | Nested object mutation still changes the original object |
| StreamPeerBuffer `data_array` getter / setter | Both isolate packed-byte mutations |
| StreamPeerBuffer `get_data()` / `put_data()` | Read result and supplied input are isolated from buffer storage |

The same observations must pass independently in each release Web export;
engine behavior is asserted explicitly rather than inferred from native results.
Owned bytes require `duplicate()` at submission and callback return boundaries.
Deep collection duplication alone is insufficient for full simulation snapshots:
serialize nested authoritative state into canonical bytes.

## Received browser replay downloads

The positive Web ownership round also runs a production replay scene when its
selected inventory includes `test_replay_viewer_prefix.gd`. Both pinned engines
and the selected Chromium or Firefox runtime use this same gate.
The browser clicks **Download prefix**, receives the actual file, and compares
all bytes with the original selected prefix. It covers frame 301 of 610,
the complete recorded terminal ending, and a readable initial-only recording.
It then opens each received file through the production browser picker, requires
a replaced player and exact recording identity, and compares playback with the
original canonical state. Disabled seek and held-timeline clicks must emit no files.

The round retains files and screenshots in `ownership-VERSION-positive-downloads/`
beside the aggregate receipt. Three live controls reject a refused second import,
a console error after screenshot capture, and an unexpected late download.
Receipt mutation tests reject wrong types, missing boundaries, changed files,
missing screenshots and incomplete control inventories.

This advances [#290](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/290).
Its escaped-descendant adoption, pre-import Python helper/cache binding and
interpreter provenance controls remain open. The gate does not establish the
broader browser release matrix or complete replay parity.

## Tested representation decision

Use fixed-capacity library-owned slots for snapshots and fixed-width input
history. The input probe writes two bytes into a preallocated slot before
returning, mutates caller and callback buffers, then reads the same original
bytes twice. Both histories use staging bytes, reserving two buffers
of the configured maximum size per slot in this prototype. A writer copies into
staging and publishes only after success; overflow is sticky and preserves the
previous snapshot. Record exact used length, frame, generation and a canonical
checksum. Reader byte returns and checksum returns are copies. All operations
remain bounded by capacity; no silent truncation occurs.

A three-slot ring keeps snapshot A protected while B and later snapshots reuse
the other slots over four wraps. Attempts to overwrite A are rejected. Reloading
A returns exactly `010203` after caller scratch reuse and nested-state mutation.
Its first byte is serialized from the original nested `State.value`; decoding
that byte after the wraps restores a fresh object to 1 while the original
object remains mutated to 9.
After explicitly releasing protection and replacing A, both its old frame and
old generation are rejected. Views expire at completion; stale reads report
`EXPIRED_VIEW` through status and stale writes return that code.

The capacity-four fixture tests exact capacity, capacity plus one, sticky write
failure, preservation after a failed save, shorter state, inaccessible unused
tail, reader underflow and trailing-byte rejection. Checksum bytes are the first
16 bytes of SHA-256 over exact canonical payload bytes, with an independent
known-answer value for `010203`: `039058c6f2c0cb492c533b0a4d14ef77`.
This is a probe algorithm choice, not an interoperability promise or a replacement
for comparing the full canonical bytes.

## Limits

These tests select and exercise a representation; they do not implement
FortressSession, callback error result types, input scheduling or the production
snapshot API. The fixture exposes GDScript internals by convention; production
must not return its slot objects or backing arrays to game callbacks. Production
must additionally validate configuration and frame/generation overflow before
allocation, enforce request identity/reentrancy, and expire every operation
through the typed `EXPIRED_VIEW` result, including read failure.

The experiment measures aliasing and bounded lengths, not allocations per frame,
copy timing, total-budget arithmetic or worst-case game payload performance.
No macOS, Windows, Firefox, Safari, mixed-engine network session or production
rollback parity is demonstrated. A protected old snapshot cannot coexist with
unlimited new saves in a finite modulo ring: collision rejection is the required
outcome, and callers must respect their configured retention budget.
