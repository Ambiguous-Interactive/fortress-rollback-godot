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

The [SignalFish relay guide](../signalfish-relay.md) provides a pinned local-server
build and real native 2/4/8-player gameplay witness. Its native evidence remains
separate from browser and direct WebRTC release gates.

`fetch.py` verifies cached archives on every use and compares their extraction
against source caches before a Rust run. Byte-identical trees retain timestamps;
changed trees are replaced. Changes made to cached upstream sources are
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

The addon-only candidate exclusion audit is reproducible independently of the
development cache. It includes runtime attribution, rejects tools and symlinks,
and executes a driver tick plus real two-peer handshake/input/ACK delivery
in a clean project using only the addon:

```sh
python3 scripts/reference/package_audit.py \
  --godot .cache/reference/editors/4.3/Godot_v4.3-stable_linux.arm64 \
  --output /tmp/fortress-addon-b1-4.3
```

Repeat with 4.7.2 and the corresponding verified executable.
[package-baseline.json](package-baseline.json) records both observed passes,
archive contents/digests and engine identity. This is a candidate packaging audit,
not release publication or supported browser/networking evidence.

B1 requires formal-tool pinning, not model execution. The TLC 1.8.0 jar was
downloaded and its manifest digest verified; scoped formal execution belongs to V5.
The reviewed October 6 build is preserved at
[`scripts/oracle/tools/tla2tools-94d0c507.jar`](../../scripts/oracle/tools/tla2tools-94d0c507.jar).
Its SHA256 remains `7beec0f04818732a62fa193731711a99aa4f11279499b2360a7d156c519ea78d`.
The artifact's `repository_path` is authoritative; its original URL records provenance.
Upstream's prerelease workflow deletes and replaces the `v1.8.0` artifact and tag
on master builds. Fresh online and offline runs verify the repository fixture before
using a cache. See the [tool provenance and licenses](../../scripts/oracle/tools/README.md).
B1's baseline and packaging evidence is now available for closure review.
The selected baseline does not cover optional Rust features, the full upstream
suite, all player counts, SignalFish runtime, mixed browsers or Safari devices.
This baseline does not claim a model execution.
Firefox/WebKit revisions are recorded from the pinned Playwright registry.
The baseline executes Chromium; the separate [WebRTC witness](../signalfish-webrtc.md)
also offers experimental manual Firefox and mixed Chromium/Firefox selection;
eight-player CI acceptance remains unresolved. Platform-specific overrides remain
in that registry. Rust-specific Kani/Z3/Loom gates belong to the later scoped verification
work, not this representative native test selection.

Artifacts use upstream published hashes when available (Godot 4.3 uses its
published SHA512 sums; newer Godot/TLC use release API SHA256 digests). Source
and browser archive SHA256 hashes were measured from the fetched immutable
revision/build URLs. This establishes reproducible integrity, not a signature
or independent trust proof. Review intentional pin updates together with evidence.
