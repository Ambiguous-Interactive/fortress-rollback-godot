# Infrastructure Test Evidence

Use for subprocess runners, receipts, staging, tool provenance and caches.

Tool probes must check process exit status before accepting version text or a
completion marker. Test both empty failures and plausible output followed by
nonzero exit. A completed result stream must account for every selected test,
including expected-panic cases; reject partial output even if listed tests pass.

Decode structured UTF-8 child-process output with explicit `encoding="utf-8"`
and strict errors. A successful JSON parse after locale decoding can still
contain corrupted feedback. Exercise real emitted bytes under a forced non-UTF-8
parent decoder, including malformed stdout and stderr; mocks returning decoded
strings cannot expose this boundary. Decoding failures must report sanitized
errors without revealing captured CLI output or credentials.

Invalidate a prior success report before starting a new attempt, clear only the
runner-owned logs, and preserve partial stdout/stderr on timeout. Capture
bounded in-loop state snapshots before the outer watchdog when
the inner timeout can occur later: include pending work and receipt/status
gossip needed to distinguish throughput from confirmation stalls. Local passes
do not supersede CI failures for the same source candidate. A failed rerun
must never leave a stale success receipt beside logs from its replacement.
Finalize fixtures before declaring a verification snapshot frozen. An intervening
edit restarts affected fresh-process and source-inventory checks.
Validate fresh service startup as well as warm state: asynchronous catalogs may
need bounded readiness polling rather than one successful configuration read.

Run the full CI entry point with its declared per-process watchdog. Size the
full-suite budget from completed runs without relaxing focused hang controls.

Keep a copied probe's exact case inventory, native selection and Web host selection
aligned when extending a shared suite. Verify preload dependencies are copied;
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

## Faster local iteration

`make test-godot` runs each suite in its own fresh-process pair across CPUs, slowest first from `.cache/tests/durations.json`;
suites over four seconds run one pair per case. Its record matches `--jobs 1`. `make test-focus SUITE=res://tests/unit/x.gd`
selects one suite. `make test-changed` runs only suites reaching files changed since `origin/main`. Deliver all suites.
The oracle launcher defaults to four independent scenario workers; `--jobs 1`
selects serial diagnosis. Preserve deterministic receipt order and unique logs.
Concurrent native launchers must use distinct `--results` paths: a focused review
can overwrite the default `latest.json` receipt from a full-suite run.
Clear owned success receipts on parse and execution-option rejection, including
malformed worker values; real subprocess controls verify mode isolation and help.

Keep verified source timestamps when bytes, modes, entry inventories and symlinks
match freshly extracted pinned archives. A timestamp-only cache or a hash of an
old receipt is insufficient. Cache downloaded Cargo crates and registry indexes,
then unpack afresh: Cargo does not revalidate already-unpacked `registry/src`
against crate checksums. Never restore that source tree as trusted CI evidence.
