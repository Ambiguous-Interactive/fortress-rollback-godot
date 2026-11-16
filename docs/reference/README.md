# Reference baseline

[B1](https://github.com/wallstop/fortress-rollback-godot/issues/12) establishes
an executable research baseline before the GDScript port. [pins.json](pins.json)
is the machine-readable source/tool manifest. The source and tool revisions were refreshed on 2026-10-28.
Godot current stable was checked against the upstream release API and remains 4.7.2.
Frozen historical receipts and golden files retain their original provenance.

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
from the other runner are preserved. It uses Rust 1.99.1, the upstream checked-in lockfile,
`--locked --no-default-features`, no optional features, one test thread,
`PROPTEST_RNG_SEED=1` and `PROPTEST_RNG_ALGORITHM=xs`. The network smoke uses
upstream's fixed seeds `1,2,3,5,8,13,21,34` for 2, 3 and 4 players.

Two local probes that share `.cache/reference/` damage each other: one deletes
the other's logs and both write the same project and export trees. The
ownership probe therefore claims those paths before it uses them. A second
local run reports who holds the claim instead of overwriting the first run's
work. Continuous integration never contends, because every job has its own
checkout and cache directory.

The repeated-trace test compares real upstream traces internally; the outer
runner additionally compares test outcome records. Outcome equality alone
cannot establish byte/state/trace identity. The planted state-divergence test
verifies that the upstream oracle and in-band detector reject that fault.

For an actual web export and Chromium run, install the locked Playwright package
in the cache. Current probes select Node 26.12.1 and Playwright 1.64.1.
Chromium executable paths are pinned per architecture because archive layouts differ. `npm ci` verifies
all package tarball integrity from the checked-in lockfile. Chromium downloads
are separately verified against the SHA256 manifest and their installed members;
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

Godot editor and Chromium preparation compare every archive member's bytes and
permissions. Unchanged files keep their inode and timestamps. Changed files are
written beside the destination, verified, then atomically replaced. An already
running executable keeps its original inode until it exits; preparation never
truncates it. Concurrent preparations of the same immutable pin need no cache
lock or per-run engine copies. Launcher project, export and receipt ownership
still requires serialization. Firefox's fresh installation remains serialized.

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

The cache and the container's scratch are machine-local and disposable. The
[cache hygiene guide](../cache-hygiene.md) documents how to report and reclaim
them without touching cited evidence.

Source archives preserve upstream notices in their original locations:
Fortress `LICENSE`, `LICENSE-MIT`, `LICENSE-APACHE`; SignalFish SDK
`addons/signal_fish/LICENSE`; SignalFish server `LICENSE`. These sources and
their tests/models have not been copied into a runtime addon. Any later translated
fixture, model or implementation must retain its source revision, transformation
and applicable attribution. Godot and Chromium notices are preserved within
cached upstream distributions.

## Upstream drift classification

Task M1 (#51) owns conservative drift detection between the reviewed pin and
an observed upstream tree. `drift.py` compares two trees of one pinned source,
classifies every changed path (production source, tests/models/fixtures,
dependencies, build logic, documentation), narrows Rust diffs into signals
(whitespace/comment-only, constants, attributes/macros, cfg gates), pairs
same-content renames, and maps each path onto its parity-ledger decision. It
never claims semantic equivalence: every non-noise change lands in the report's
`requires_review` list, unmatched paths fail closed, and a broken input is a
tooling error with a nonzero exit instead of a no-drift report:

```sh
python3 scripts/reference/drift.py --source fortress --old REVIEWED_TREE --new OBSERVED_TREE \
    --ledger docs/reference/parity-ledger.json --report drift-report.json
```

### Observation and advancement

The pin flow binds the compared trees to the archives you supply before any
bookkeeping is recorded: the candidate archive is digested, extracted and
required to match the compared tree byte for byte, and `--old` must byte-match
the reviewed pin's cached archive (taken offline from the fetch cache against
the manifest digest — run `python3 scripts/reference/fetch.py` first; a cold
cache refuses with a named error). Supply the codeload archive for the
claimed revision: the recorded candidate digest is proven to be the upstream
archive when the next fetch verifies it. Without `--advance` the tool only
records the observation under
`sources[name].review` (`observed_revision`, `observed_on`, and the report and
archive digests); with `--advance` it additionally rewrites the pin itself —
`revision`, archive URL, digest and root — records `advanced_from` and
`advanced_on`, and stamps every changed path with a commit link. Every recorded
field is validated by `fetch.load_manifest`, so malformed bookkeeping fails the
next manifest load. Extract the observed tree from the same archive you pass,
because the binding compares byte for byte including file modes:

```sh
curl -L -o /tmp/candidate.tar.gz https://codeload.github.com/wallstop/fortress-rollback/tar.gz/<sha>
mkdir -p /tmp/candidate && tar -xzf /tmp/candidate.tar.gz -C /tmp/candidate
python3 scripts/reference/drift.py --source fortress \
    --old .cache/reference/fortress-rollback-<reviewed-sha> \
    --new /tmp/candidate/fortress-rollback-<sha> \
    --pins docs/reference/pins.json --new-revision <sha> \
    --archive /tmp/candidate.tar.gz \
    --ledger docs/reference/parity-ledger.json --report .cache/scratch/drift-report.json --advance
```

The report is the review evidence, not the approval: an advanced pin merges
only after a full oracle requalification run against it (the Reference
Baseline workflow runs the complete differential on every pins.json change)
and a reviewed `requires_review` list. The binding compares byte for byte
including file modes, so extract the observed tree and run the tool under the
same umask — a differently-masked extraction is refused loudly, not silently
accepted. Two boundaries stay explicit: the compared tree is bound to the
archive *you supply* (its digest is proven to be the upstream archive only
when the next fetch verifies it, which the Reference Baseline requalification
does before an advancement can merge), and `--old` is trusted to be the
verified pinned extraction (`fetch.sources` output under
`.cache/reference/`) — pass the wrong tree and the report names visible
drift, but the evidence is only as honest as that path.

### Weekly reporting

The scheduled/manual cadence and its deduplicated issue reporting are M2
(#52). The `Drift Report` workflow (Mondays 06:17 UTC, plus
`workflow_dispatch`) runs `scripts/reference/drift_report.py`: for each pinned
source it resolves the repository's default-branch revision, stops when that
revision is the reviewed pin, and otherwise downloads the candidate archive,
extracts the reviewed tree from the digest-verified pinned archive and the
candidate tree from its download, classifies the drift
through `drift.py`, and appends one observation comment — carrying a stable
`report-digest` — to exactly one ongoing issue per source. The carrier issue
is found by a stable marker in its body across open *and* closed issues, not
through the search API (whose index lags behind writes), so a closed stream
is reopened rather than duplicated and a repeated observation of an identical
state comments nothing; two carrier issues for one stream are a tooling error
that fails the run before any write. The reporter only reports: it never
rewrites `pins.json`, never advances a pin and never regenerates fixtures —
advancing stays the reviewed operator flow above, and the issue body carries
that checklist. Run it by hand the same way the workflow does:

```sh
GITHUB_REPOSITORY=Ambiguous-Interactive/fortress-rollback-godot \
python3 scripts/reference/drift_report.py --source fortress \
    --summary /tmp/drift-report-summary.md
```

Exit code 0 reports or no-ops every requested source; exit 1 names the failed
sources after the remaining ones still reported (partial failure is visible
in the workflow summary, never a silent no-drift result). The candidate
archive's sha256 is recorded in each observation, not proven: the download is
bound to the codeload URL over TLS, and a recorded digest is proven to be the
upstream archive only when a later fetch verifies it. The suite drives
the whole flow against fake adapters — creation, digest-quiet repeats,
reopen-not-duplicate, duplicate-carrier refusal, resolver and archive-binding
failures and a real `gh api` argument contract — before the schedule runs it
for real.

## Coverage certification

Task #55 owns the boundary between source-family discovery and executable
coverage certification. `scripts/reference/coverage.py` verifies a result
bundle against the parity ledger: a `covered` + `applicable` decision counts
only when every `port_test_ids` entry names a result that passed and
completed at the ledger's pinned source revision, on the bundle's declared
engine gate, with its cited artifact present in the evidence directory and
byte-identical to its recorded digest. The bundle's `run_id` is the canonical
digest of its results array and `ledger_sha256` pins the exact ledger bytes,
so tampered results and bundles certified against an older ledger fail. With
`semantic_audit_complete` set, the verified set must equal the declared
supported set exactly — no unverified supported decision, no result outside
it, and never an entirely pending ledger. Forged identities, flipped flags,
stale success JSON, partial completions, missing artifacts and stale
revisions each fail for their specific reason; exit 0 verifies, 1 fails
verification, 2 is a tooling error. The data-driven mutation table in
`scripts/reference/test_coverage.py` pins every hostile shape. This is the
verifier boundary only: producing bundles from actual port-suite executions
stays with the release-qualification work in #44.

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
