# Infrastructure Test Evidence

Use for subprocess runners, receipts, staging, tool provenance and caches.

Temporary Git repositories must clear caller Git environment overrides for every
Git command and invoking Python child. Disable unrelated global/system configuration
and the default XDG ignore file with an explicit `core.excludesFile` override.
Use `scripts/git_test_environment.py`; test with an external staged index and
verify the caller's HEAD, status and index bytes remain unchanged.

Scope diagnostic environment variables to their intended child process; unrelated
helpers can interpret the same variable differently and corrupt structured output.

Tool probes must check process exit status before accepting version text or a
completion marker. Test both empty failures and plausible output followed by
nonzero exit. A completed result stream must account for every selected test,
including expected-panic cases; reject partial output even if listed tests pass.
Executable Python test modules keep `unittest.main()` after every test class.
Verify a newly added class by direct selection as well as discovery; import-only runs can hide an early entry point.

Decode structured UTF-8 child-process output with explicit `encoding="utf-8"`
and strict errors. A successful JSON parse after locale decoding can still
contain corrupted feedback. Exercise real emitted bytes under a forced non-UTF-8
parent decoder, including malformed stdout and stderr; mocks returning decoded
strings cannot expose this boundary. Decoding failures must report sanitized
errors without revealing captured CLI output or credentials.

Invalidate a prior success report before starting a new attempt, clear only the
runner-owned logs, and preserve partial stdout/stderr on timeout. Identify the failed
command with a fixed phase label; dumping arbitrary arguments or environment can expose credentials. Capture
bounded in-loop state snapshots before the outer watchdog when
the inner timeout can occur later: include pending work and receipt/status
gossip needed to distinguish throughput from confirmation stalls. Local passes
do not supersede CI failures for the same source candidate. A failed rerun
must never leave a stale success receipt beside logs from its replacement.
Finalize fixtures before declaring a verification snapshot frozen. An intervening
edit restarts affected fresh-process and source-inventory checks.
Coordinate one source freeze across parallel agents when launchers fingerprint an entire
helper directory, even when their selected workloads are unrelated.
Inventory-contract tests also need frozen declarations and registries; importing expected cases before an author adds cases creates a mixed-source failure.
Read actual runtime settings after automation initializes; requested profile
values can be overridden before the behavior under test executes.
Validate fresh service startup as well as warm state: asynchronous catalogs may
need bounded readiness polling rather than one successful configuration read.

Run the full CI entry point under both process and job watchdogs. Successful
pages do not qualify an inventory that exceeds the job deadline. Split long
inventories into declared partitions while retaining cases, assertions and repeats.
Include cold tool/OS preparation in the outer job budget; a warm setup duration cannot reserve a valid verification window.
Localize stalled package acquisition before changing budgets again; preserve repository signature and checksum authentication when selecting mirror alternatives.
Size harness command envelopes after encoding and serialization; a binary payload cap does not include hex expansion or JSON overhead.
Dependency-only baseline refreshes must preserve readable recordings from known compatible source revisions.
Exercise original provenance metadata as well as newly generated fixtures; regenerated fixtures alone hide rejection regressions.
Bind each partition to its inventory, engine, phase and source/tool identities;
require the complete union and reject gaps or undeclared overlaps before qualification.
Shared-host runs keep one worker and known slow-case isolation; serialization must
not merge individually bounded cases into an over-budget process. Determine lease
ownership from successful lock acquisition, never from matching owner names.
Host-wide locks must coordinate independent checkout roots by default. Exercise real
cross-root contenders and keep the lock inode through pruning, even when idle;
unlinking an idle lock can race with acquisition. Validate shared directory ownership
and permissions before opening its lock. Bound child readiness reads as well as exit waits.
Verify owned descendants have exited before accepting final file inventories;
parent exit alone does not establish process-group completion.

Keep a copied probe's exact case inventory, native selection and Web host selection
aligned when extending a shared suite. Platform-specific I/O must assert equivalent
contracts with equal assertion counts when full native/Web records are compared. Verify preload dependencies are copied;
exercise the affected probe, since the root unit runner cannot prove its staging.
Freeze source/helper hashes before staging; verify copied and relocated authored bytes before adapting them.
Verify tools before use and recheck sources/tools before publication; end-only hashes cannot identify executed bytes.
When engine import creates metadata, first verify authored sources are unchanged.
Allow only metadata paired with existing inputs, then freeze the complete
post-import inventory through export and execution.
Verify supplied pinned executables against bytes extracted from the verified
archive; a version string and unchanged execution hash do not prove provenance.

For distributable archives, compare against an explicit required runtime inventory.
A clean import can succeed after an entire optional subsystem was omitted. Delete
a required subsystem and add an unknown development script as negative controls;
both must fail before constructing a successful candidate.
Exercise serialized corruption through the installed decoder and player. A mutant that
disables a validation-status getter proves reporting only; bypass the actual comparison
and require the corrupted-recording check to fail before claiming validation coverage.

Pair file producers with every advertised import path using the exact game identity and initial state,
and compare actual playback with the original canonical state. Also exercise the maximum advertised output size.
Include per-row checksums, statuses and maximum metadata; short fixtures can hide a smaller consumer cap.
Share the byte limit between native and browser pickers and test rejection one byte above it before reading.
Check the minimum valid output too: zero input rows can still carry a valid initial-state checksum.
Keep download eligibility, exported bytes and visible instructions consistent at that boundary.

Concurrent processes for one Godot project share `user://`. Give writable test
fixtures process-owned paths and check open, write and removal results before
asserting application behavior. Reproduce interference with a second process;
a missing-file test can observe a peer's recreated or truncated file instead.
`OS.get_process_id()` is unavailable on Web; use it only in native branches.
Web fixtures use the page's isolated filesystem and keep equivalent assertion counts.

The native unit runner executes suites during `SceneTree._initialize()`, before
nodes acquire live GUI focus. Direct handler calls can verify action gates, but
cannot prove viewport routing, editable focus, popup consumption or tooltip delivery. Exercise those
contracts in a deferred live scene with real input events; inspect rendering after
layout settles. Keep native/Web assertion inventories equal when platform UI differs.
Browser test hosts must also defer scene-creating suites until their own `_ready` returns.
A root already inside the tree can still reject `add_child` while setting up children;
native initialization and an independently deferred witness do not exercise that host boundary.

## Faster local iteration

`make test-godot` runs each suite in its own fresh-process pair across CPUs, slowest first from `.cache/tests/durations.json`;
suites over four seconds run one pair per case. Its record matches `--jobs 1`. `make test-focus SUITE=res://tests/unit/x.gd`
selects one suite. `make test-changed` runs only suites reaching files changed since `origin/main`. Deliver all suites.
Direct launcher calls default to 30 seconds; pass `--timeout 180` when selecting long stress or full-duration replay cases, as the full Makefile target does.
The oracle launcher defaults to four independent scenario workers; `--jobs 1`
selects serial diagnosis. Preserve deterministic receipt order and unique logs.
Concurrent native launchers must use distinct `--results` paths: a focused review
can overwrite the default `latest.json` receipt from a full-suite run.
Keep a subagent's verification turn active until its child processes finish.
Parent agents may not be able to poll child-owned tool sessions; hand back
completed receipts instead of assuming session IDs transfer. The handoff must
identify the full selected inventory, engine, phase and source/tool identities,
include source hashes, and record the child's terminal exit status. Attach that
status separately when the receipt schema does not store it. Partial inventories
or missing exit status do not qualify as completed verification.
For reproducible oracle commands and receipt provenance, see
[replay probes](../../../../docs/oracle-replay.md) and
[spectator probes](../../../../docs/spectators.md).
Clear owned success receipts on parse and execution-option rejection, including
malformed worker values; real subprocess controls verify mode isolation and help.

Keep verified source timestamps when bytes, modes, entry inventories and symlinks
match freshly extracted pinned archives. A timestamp-only cache or a hash of an
old receipt is insufficient. Cache downloaded Cargo crates and registry indexes,
then unpack afresh: Cargo does not revalidate already-unpacked `registry/src`
against crate checksums. Never restore that source tree as trusted CI evidence.
