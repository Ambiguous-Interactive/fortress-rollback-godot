# Reference baseline

[B1](https://github.com/wallstop/fortress-rollback-godot/issues/12) establishes
an executable research baseline before the GDScript port. [pins.json](pins.json)
is the machine-readable source/tool manifest. These pins remain the research
revisions in PLAN.md; no source revision was advanced. Godot current stable was
checked against the upstream release API on 2026-10-10 and is pinned to 4.7.2.

The contract is that an unavailable source, corrupt archive, missing tool,
unavailable feature, empty/partial test run or browser script error fails
explicitly. Successful runs mean only the selected existing upstream tests and
engine/codec probes passed. They do not establish addon parity.

## Setup and reproduction

Run commands from the repository root on Linux arm64 or x86_64. Python 3.12+
provides the stdlib downloader and safe tar extraction. Rust is development
only and installs below `.cache/reference`, never in the addon.

Native prerequisites are a C compiler, `clang`, `lld` (required by the pinned
upstream Cargo configuration), and Godot's system libraries. On Ubuntu 24.04:

```sh
sudo apt-get update
sudo apt-get install -y clang lld libfontconfig1 libx11-6 libxcursor1 libxinerama1 libxi6 libxrandr2 libasound2t64
python3 -m unittest discover -s scripts/reference -p 'test_*.py'
python3 scripts/reference/fetch.py
python3 scripts/reference/run.py --setup-rust
python3 scripts/reference/godot_smoke.py
```

The Rust runner selects five cases, runs each twice, verifies completed nonempty
passing test identities/counts, and stores JSON and raw logs in
`.cache/reference/results`. Each invocation deletes its prior report and owned
logs before loading pins or tools. A failed run leaves no successful report;
partial timeout output is saved with an explicit `TIMEOUT` diagnostic. Artifacts
from the other runner are preserved. It uses Rust 1.94.0, the upstream checked-in lockfile,
`--locked --no-default-features`, no optional features, one test thread,
`PROPTEST_RNG_SEED=1` and `PROPTEST_RNG_ALGORITHM=xs`. The network smoke uses
upstream's fixed seeds `1,2,3,5,8,13,21,34` for 2, 3 and 4 players.

The repeated-trace test compares real upstream traces internally; the outer
runner additionally compares test outcome records. Outcome equality alone
cannot establish byte/state/trace identity. The planted state-divergence test
verifies that the upstream oracle and in-band detector reject that fault.

For an actual web export and Chromium run, install the locked Playwright package
in the cache. Node 22.23.3 was used for the recorded baseline. `npm ci` verifies
all package tarball integrity from the checked-in lockfile. Chromium downloads
are separately verified against the SHA256 manifest and extracted freshly;
the Playwright browser registry must also match its pinned digest.

```sh
mkdir -p .cache/reference/browser
cp scripts/reference/browser/package*.json .cache/reference/browser/
npm ci --ignore-scripts --prefix .cache/reference/browser
sudo .cache/reference/browser/node_modules/.bin/playwright install-deps chromium
python3 scripts/reference/godot_smoke.py --web
```

Each editor archive and its matching export-template package has a reviewed
digest. The runner builds isolated generated projects, runs the little-endian
codec probe twice headless, rejects an actually invalid GDScript program,
exports the same probe for web, and launches pinned Chromium. It requires the
marker set by the exported GDScript, rejects browser errors, and records the
actual browser version. A served page or HTTP 200 is insufficient.

## Cache and provenance

`fetch.py` verifies cached archives on every use and re-extracts sources from
those archives before a Rust run. Changes made to cached upstream sources are
intentionally discarded; cache trees are not working checkouts. Do not run
source-consuming commands concurrently with source re-extraction.

`--offline` requires all selected artifacts to exist and match their digests.
A missing or corrupt cache fails; it is never silently repaired or replaced by
`main`, a tag, a floating stable compiler, an installed Godot or another browser.
Rust offline runs additionally need the compiler and Cargo dependency cache.
First fetch all sources and execute the desired native/web baseline online,
then repeat with:

```sh
python3 scripts/reference/run.py --offline
python3 scripts/reference/godot_smoke.py --offline --web
```

Source archives preserve upstream notices in their original locations:
Fortress `LICENSE`, `LICENSE-MIT`, `LICENSE-APACHE`; SignalFish SDK
`addons/signal_fish/LICENSE`; SignalFish server `LICENSE`. These sources and
their tests/models have not been copied into a runtime addon. Any later translated
fixture, model or implementation must retain its source revision, transformation
and applicable attribution. Godot and Chromium notices are preserved within
cached upstream distributions.

## Evidence and remaining gates

[baseline.md](baseline.md) records actual results, exact selections, negative
controls and limitations. Checked-in JSON summaries preserve the observed
source/tool versions, test identities, semantic equality and artifact hashes.
CI uploads raw logs; local logs stay in the ignored cache.

B1 remains open until its remaining gates are demonstrated, including any
required formal-tool setup/model runs and the eventual addon release-package
exclusion check. The current repository has no addon release artifact to audit.
The selected baseline does not cover optional Rust features, the full upstream
suite, all player counts, SignalFish runtime, mixed browsers or Safari devices.
TLC 1.8.0 is artifact-pinned; this session does not claim a model execution.
Firefox/WebKit revisions are recorded from the pinned Playwright registry;
only Chromium is executed here. Platform-specific overrides remain in that
registry. Rust-specific Kani/Z3/Loom gates belong to the later scoped verification
work, not this representative native test selection.

Artifacts use upstream published hashes when available (Godot 4.3 uses its
published SHA512 sums; newer Godot/TLC use release API SHA256 digests). Source
and Chromium archive SHA256 hashes were measured from the fetched immutable
revision/build URLs. This establishes reproducible integrity, not a signature
or independent trust proof. Review intentional pin updates together with evidence.
