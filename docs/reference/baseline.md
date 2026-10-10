# Baseline observations — 2026-10-10

Hypothesis: the three research revisions remain available; the selected real
upstream sync/queue/seeded-network behavior reproduces with a pinned compiler,
features and lockfile; minimum/current editor and matching web templates execute
a simple GDScript byte-codec probe. This is prerequisite evidence for
[B1](https://github.com/wallstop/fortress-rollback-godot/issues/12), not port parity.

## Actual results

Host: Linux aarch64, Ubuntu 24.04, Python 3.12.3, Node 22.23.3, npm 10.9.9.
Rust: 1.94.0, Cargo 1.94.0, rustup 1.29.1. All source revisions and archive
integrity checks passed; [pins.json](pins.json) records the exact values.

| Command selection | Observed result | Contract |
| --- | --- | --- |
| `--lib input_queue::` | 115 passed, twice | Existing queue boundaries/prediction/discard/property tests |
| `--test sessions synctest::` | 8 passed, twice | Existing sync-test sessions |
| `--test simulation simulation::fleet::pr_smoke_` | 3 passed, twice | Real mesh oracle at 2, 3, 4 peers, 8 seeds each |
| `--test simulation simulation::fleet::same_schedule_produces_identical_trace -- --exact` | 1 passed, twice | Upstream assertion compares traces for the same schedule |
| `--test simulation simulation::fleet::oracle_and_inband_detector_catch_seeded_state_divergence -- --exact` | 1 passed, twice | Planted divergence is detected independently and in-band |
| Godot 4.3 native | Marker `78563412`, twice | GDScript little-endian byte codec executes |
| Godot 4.7.2 native | Marker `78563412`, twice | Same probe on current stable |
| Godot 4.3 exported Web | Chromium 141.0.7390.37, marker, no browser errors | Real exported GDScript executes |
| Godot 4.7.2 exported Web | Chromium 141.0.7390.37, marker, no browser errors | Matching current editor/template executes |
| Actual invalid GDScript, each editor | Parse failure rejected | A zero-exit engine error cannot satisfy smoke |

Exact commands, feature selection, source revisions, test identities and observed
versions are preserved in [rust-baseline.json](rust-baseline.json) and
[godot-baseline.json](godot-baseline.json). Run commands in [README.md](README.md)
reproduce these selections and retain their raw logs. The Rust report hashes
both logs and the normalized completed test outcomes per selection.

Primary pinned source:
[queue](https://github.com/wallstop/fortress-rollback/tree/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/input_queue),
[sync tests](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/tests/sessions/synctest.rs),
[mesh/trace/oracle tests](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/tests/simulation/fleet.rs).
The mesh seeds are `1,2,3,5,8,13,21,34`; property tests use explicit seed `1`
and xorshift. No golden expectation or upstream source was changed to pass.

## Red-green evidence and setup discoveries

Before the baseline tooling existed, no manifest/setup/run command established
these gates. Negative controls now explicitly reject missing/malformed source
SHAs/digests, missing offline artifacts, wrong cached digests, empty/partial test
logs, ignored/failed tests and mismatched running/completed counts. Engine
failure tests reject tool exit failures and script errors even with exit zero.

The first bootstrap attempt used x86_64 Rust on this arm64 host and failed with
an ELF loader error. Bootstrap now selects the host architecture and fails
unsupported hosts explicitly. The first runner invocation from upstream's tree
failed because its `.cargo/config.toml` requires `clang` and `lld`; installing
those development dependencies fixed the actual cause. Tightening completed-test
count validation exposed an initially omitted expected-panic test in the result
parser; the corrected parser records all 8 sync tests, including the panic contract. The original exploratory
`--manifest-path` queue command run from the port root had passed with GCC;
that was not used as the final reproducible result.

The first Godot web export printed `ERROR:` for missing `include_filter` and
`exclude_filter` despite writing output and exiting zero. The smoke runner
rejected it. Supplying a complete preset fixed the configuration; projects and
exports are regenerated from scratch to prevent a prior cached preset from
contaminating later runs. The final actual exported page and browser probe pass.
The deliberately invalid GDScript produces an actual parse error on both
editors and is rejected before recording success.

Fresh review found that a failed rerun could leave a prior successful JSON report
and that a timed-out subprocess could leave an old successful log. Six red
subcases reproduced these failures before repair. Both runners now invalidate
their reports and owned logs before manifest/tool setup; timeouts retain partial
stdout/stderr and an explicit diagnostic. Regression cases also fail after a
successful tool-version/import step and prove the other runner artifacts survive.
The 16 reference/inventory tests pass after repair, followed by actual offline
Rust and native/web reruns to regenerate current successful evidence.

## Evidence limits and open gates

No selected upstream test failed after setup. This is a representative selection,
not an assertion that the entire upstream suite or optional features are green.
Matching normalized completed test outcomes does not independently compare
runtime state; trace identity is provided by the named upstream trace test.

The engine/web probes exercise loading and byte serialization only. No addon
implementation, SignalFish session, rollback scenario, all-count 2–8 matrix,
mixed-browser network or Safari/device behavior is demonstrated here.
Firefox/WebKit and TLC are pinned; those engines/models were not executed.
This baseline has no claim about Rust Kani/Z3/Loom proofs transferring to Godot.

All upstream/Rust/browser/template material remains under the ignored
`.cache/reference/` development directory. Repository scripts and browser package
files are development tools.

## Session 007 closure audit

The current pin manifest matches both checked-in and cached Rust/Godot baseline
reports. All ten Rust raw logs match their report SHA256 digests, with the
115/8/3/1/1 selections passing twice. Cached source, compiler metadata, minimum/
current editors/templates and Chromium archives match their manifest digests.
The pinned TLC 1.8.0 jar was fetched and its SHA256 verified; B1 requires pinning,
while formal model execution remains V5 work.

Fresh closure reproduction also passed every selection twice:

```sh
python3 scripts/reference/run.py --offline --output .cache/session-007/b1-rust
```

The output report and ten fresh logs preserve the same revisions, features,
seed and complete passing test identities. No live source consumer overlapped
this run. Verified byte-identical source caches retained their timestamps.

The [addon package audit](package-baseline.json) creates a real candidate tar
outside the repository, verifies its exact twelve runtime/attribution entries,
and extracts it into a fresh project. Actual Godot 4.3 and 4.7.2 each run the
driver's first tick successfully using only that extracted addon. No test,
reference, Rust, C#, extension binary or browser tooling is packaged. Required
repository and upstream MIT notices are included. Eight negative controls reject
Rust, extensionless tools, missing/empty/altered notices, symlink directories and
nonregular entries before any
engine execution, and invalidate stale successful receipts.

This resolves B1's packaging exclusion gap; it does not certify a supported
release, P2P transport or browser rollback. The baseline, integrity, fail-closed
controls and packaging evidence are ready for issue closure review after the
session PR passes current-head CI and review.
