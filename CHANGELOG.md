# Changelog

## [Unreleased]

### Added

- **Give owned-process waves an external cancellation handle (#397)**: `owned_process.run` and `run_split` accept a `CancelHandle` — a bounded, thread-safe surface that pins one running call's process group and token, so a caller that joins several owned commands concurrently can stop one member from outside its call. `cancel()` performs the deadline path's ownership work from another thread: the group kill, both ownership sweeps with pidfd-pinned kills, and one merged survivor report; the owning call still reaps its own child, verifies the tree is gone, writes the report beside a `CANCELLED` marker into the log the caller reads and raises `owned_process.Cancelled` carrying the partial output. A shared named-pid registry settles every sighting between the cancel's sweeps and the owning call's own sweeps, so a pid is named exactly once across both reports — the #381 regression class extended to the new path — and the deadline, interruption and escape paths claim through the same registry. A second cancel is refused (`ValueError`), an already-cancelled handle is refused before any process starts, a cancel landing in the start-to-registration window cleans the just-started tree up before refusing, and the fallback surface without process groups refuses cancellation instead of silently ignoring it. The browser witness wave wires it end to end: every packed wave member runs under its own handle and an interrupt in the joining caller cancels every active label's tree before joining the workers, so the wave ends within cleanup time instead of at each member's remaining deadline, while ordinary per-label failures keep the join-all naming in label order and single-label serial plans keep the inline call exactly as it was. Red-green: the live wave test drives slow child trees, interrupts the joiner with a real SIGINT mid-join and requires every tree reaped before the join returns well inside the members' own deadlines; the control keeps the joined-failure semantics without an interrupt; hostile double-cancel, refused reuse, raced registration and the once-only naming (a setsid token carrier named by exactly one report) are pinned per path.

- **Publish the P2P supported-profile report (#34, #59)**: `docs/reference/p2p-profiles.md` publishes the initial P2P scope's supported network profiles and the reproducible zero-unexplained-divergence report behind them — what "supported" means (a committed case in a differential launcher, pinned upstream revision, both engine pins, twice per side in fresh processes, fail-closed on any disagreement), the one-command wave reproduction, the compared matrix by axis (roster 2–8 at delay 0/2, loss/reorder/stall/retry faults at 2/4/8, prediction windows 4 and 8, heterogeneous construction-delay profiles plus the raise differential and its minimized regression, runtime delay changes, solo/couch/split endpoint layouts, widths 1/default/32 including the combined maximum profile, the complete ring-wrap flood family, asymmetric recovery across queue wrap, the lifecycle corpus and the 26-scenario handshake matrix), the declared exclusions (three-or-more-identity low-window meshes, Rust/Godot mixed wire sessions, live transports and browsers, beyond-representative widths and windows, advanced parity, the Godot-only lockstep SAVE extension) and the explained divergences (initial-save dedup, the stall projection, `inputs_received`, the terminal-policy projection, the replay-only #253 discrepancy, raise-send timing, the pre-first-input delay refusal). `scripts/oracle/profile_report.py` renders the page's inventory block — 104 cases across the handshake, p2p and wrap launchers — from the same case tables the launchers execute, after `p2p_launch.corpus()` moved onto one `case_builders()` table so the executed case set and the published inventory share a single source of names in a single order; `--check` fails closed when the committed block drifts from those tables (exit 1 drift, exit 2 tooling error) and `--write` regenerates it in place. Red-green: the report tests fail on the missing tool before it exists and pass after; the derived case order is asserted element-by-element identical to the pre-refactor loop order; the drift control names a tampered inventory line and the CLI exit contract is pinned by a subprocess test.
- **Wrap flood on the split and asymmetric layouts and the minimum width (#34, #59)**: the ring-wrap flood corpus closes its remaining named axes with three committed fixtures. `mesh_4_wrap_flood_split_2x1x1` runs the four-peer total-silence flood across three machines — one owning two local slots beside two solo machines — so records and evidence address three machines while four slots step (2213 measured scheduled operations, 1646 packets; 134 confirmed boundaries per machine past the default 128-row ring through a three-row LOAD heal). `mesh_4_wrap_flood_couch_3x1` holds the asymmetric two-machine shape — one couch machine owning three local slots beside one solo machine — so the largest compared flight row carries three slots' inputs in one packet (1128 operations, 558 packets; 137 confirmed boundaries per machine through the four-row heal). `mesh_4_wrap_flood_width_1` wraps the same default ring at the compared minimum width with byte-identical schedule shape to the wide case (3828 operations, 3266 packets; 134 predicted advances, six silent stalls, one three-row heal and 134 confirmed boundaries per machine). Both pinned engines match the pinned upstream twice per side in fresh processes with raw compression validation, per-machine wrap evidence and the full negative-control set.
- **Track each multi-slot wrap machine's own frame in the flood builder (#34, #59)**: a multi-slot machine advances on the first step that submits a covered row — the staged row stays covered across refused advances, so after the flood release un-caps the frontier that is the machine group's first slot and its later slots land on the already advanced frame. The builder's per-round model derived those later slots' bytes from the stale round frame, submitting one machine frame under two different byte rows: the trace contract's changing-stalled-sample refusal fired on the three-machine split's very first build. Layout builds now observe the trace after every slot step and re-derive the owning machine's frame from that observation, so every payload follows the machine's own current frame; the per-round observation stays for solo meshes, and all fourteen committed solo fixtures rebuild byte-identically through the corrected builder (verified digest-for-digest). The committed couch case regenerates with its dynamics unchanged — same 1128 operations, 137 boundaries, seven silent stalls and four-row heal per machine on both pins — with only its second-slot payloads moved onto their real frame. The evidence gate's profile-identity binding test now drifts on a grammar-valid but uncommitted capacity/width combination, because the width axis no longer has an uncommitted member.
- **Wrap flood on wide input rows (#34, #59)**: `mesh_4_wrap_flood_width_32` runs the four-peer total-silence flood on wide 32-byte rows wrapping the default 128-row ring — 3828 measured scheduled operations, 3266 packets — so every wrapped flight row, XOR-delta decoder reference and confirmed fold runs at the compared maximum width while the flood freezes and heals the frontier: per machine, 134 predicted advances, six silent stalls, one three-row LOAD heal and 134 confirmed boundaries past the ring on both engine pins, twice per side with raw compression validation. The wrap profile table gains the input width as its seventh field (None stays the four-byte default), the builder stamps `input_width` and derives wide payloads in which every byte stays nonzero and varies with its position, the modeled frame and the slot, so the fold contribution lives in the tail bytes too while positional comparison keeps aliased rows from aliasing any check; the evidence gate binds the profile identity including the width, the fixture loader refuses width drift beside its digest, and the lifecycle control path — whose generic width controls were unreachable — proves its own row comparison with a new `wide_tail` mutant that flips a wide row's final byte and must fail the exact packet comparison. Red-green: the loader check is pinned by a hand-edited fixture with a re-stamped digest and shrunk rows, the lifecycle branch by a mutation-free control set, and the builder/evidence width guards by hostile-width and wrong-profile cases against the committed fixture.
- **Wrap flood across couch machines with several local slots (#34, #59)**: `mesh_4_wrap_flood_couch_2x2` runs the four-peer total-silence flood across two shared-address machines that each own two local slots, so every confirmed row folds two local samples per machine and the released burst heals both machines' flights through one deep LOAD correction — both pins confirm 137 boundaries per machine past the default 128-row ring through seven silent stalls and a four-row heal. An explicit layout cannot carry the lifecycle section that pins engine timers, so layout scenarios run the oracle's omitted-lifecycle defaults — inert quality/keepalive/notify/timeout timers, the same shape the solo profiles' explicit values pin — while the genuine upstream default `DesyncDetection::On { interval: 60 }` stays in force, so its default checksum reports stay part of the compared packet traffic past frame 60: the trace contract admits checksum reports (only) for layout scenarios without a lifecycle section, the trace driver publishes and validates them on the Godot side, and the wrap evidence gates its per-machine witnesses over machines instead of slots.
- **Real-browser witnessing as a verified devcontainer capability (#385)**: the devcontainer image installs one apt layer with exactly the union of the pinned `@playwright/test` 1.64.1 dependency libraries for ubuntu 24.04 (Chromium + Firefox lists) plus `xvfb` and `xdotool`, while the digest-bound Chromium and Firefox builds from `docs/reference/pins.json` and the pinned Playwright package are acquired at post-create through the fail-closed reference path (`scripts/reference/devcontainer_browsers.py`, `npm ci --ignore-scripts`) into the cache layouts the harness already reads — image builds stay fast and the pins stay authoritative. The acquisition records `.cache/reference/browser-env.sh` with the same `FORTRESS_CHROMIUM_EXECUTABLE` / `FORTRESS_FIREFOX_EXECUTABLE` / `FORTRESS_PLAYWRIGHT_PACKAGE` variables CI's browser suites consume (sourced from `~/.bashrc` once), so the skip-gated suites stop silently skipping in devcontainer sessions. `.devcontainer/verify.sh`'s new **Browser witnessing capability** section runs in full and `--quick` modes and fails closed — acquisition record, all three variables, both executables, the download and registry digests against `pins.json`, and one real headless Chromium launch plus one `xvfb-run` Firefox launch — and Devcontainer Verify exercises the same section inside the freshly built container on x64 and arm64, so local and remote verification share one environment definition. Red/green evidence: the pre-change container failed the section with named reasons (`libglib-2.0.so.0: cannot open shared object file`, missing acquisition record, `xvfb-run: No such file or directory`); after the change both launches pass on arm64 (Chromium 156.0.8078.4, Firefox 157.0); a corrupted cached zip is refused with the pinned digest by both the acquisition and the verifier; and a hostile executable removal fails the launch witness with `EACCES` instead of skipping. Contract tests pin the exact library list, the no-skip placement outside the `--quick` gate, the acquisition order and the witness's named refusals.
- **Drift report runs under the scheduled identity (#52)**: the weekly/manual workflow now passes `--reporting-identity github-actions[bot]` explicitly, because the Actions installation token cannot resolve the authenticated user (`gh api user` answers HTTP 403 for installation tokens) — the first manual dispatch failed every source at identity resolution for exactly that reason. A hand run without the flag keeps resolving its identity; digest trust follows whichever identity produced the observation, so the same-identity quiet cadence is unchanged. Contract tests pin the workflow flag and the override path (resolution never runs; the named identity owns its digests).
- **Wrap flood on the nine-row ring (#34, #59)**: `mesh_4_wrap_flood_capacity_9` runs the four-peer total-silence flood on the capacity profile's nine-row ring, so every peer confirms 16 boundaries — seven rows past the ring — through one deep LOAD heal on both engine pins.
- **Weekly drift report (#52)**: a scheduled or manual run now classifies each pinned source's upstream drift and appends the observation to one deduplicated issue per source; it never advances a pin or edits pins.json.
- Certify ledger coverage against executed evidence (#55): the new `scripts/reference/coverage.py` implements the evidence boundary between source-family discovery and executable coverage certification. A `covered` + `applicable` ledger decision counts only when every `port_test_ids` entry names a result that passed and completed at the ledger's pinned source revision, on the bundle's declared engine gate, with its cited artifact present in the evidence directory and byte-identical to its recorded digest; the bundle's `run_id` is the canonical digest of its results array and `ledger_sha256` pins the exact ledger bytes, so a result edited without recomputing the identity, a stale bundle, or one certified against an older ledger fails for its specific reason — the digest is unkeyed and is change detection, not authentication. One identity carries exactly one verdict: a second entry for the same test identity — the stale success JSON a failed rerun leaves behind — is a named conflicting-results failure, never silently cherry-picked. Results without integer seed evidence, identities that name no executable repository test (the same `inventory.identity_error` boundary the release verification uses), `covered` decisions whose applicability is not `applicable`, and covered decisions without port-test identities all fail closed as named reasons instead of silently counting as support. `semantic_audit_complete` is held to the strict shape — the verified set must equal the declared supported set exactly, results outside it are named, and a flipped flag over an entirely pending ledger fails — so a manually flipped audit flag or a nonempty `port_test_ids` list alone can never claim coverage. Exit codes separate verification failure (1) from tooling error (2, including a missing evidence directory and non-object result entries). The data-driven mutation table covers the honest bundle passing, forged test identities, failed and partial results, wrong-engine executions, missing seeds, missing artifacts, artifact digest drift, conflicting duplicate results, stale revisions, ledger drift, tampered run identities, covered decisions without applicable applicability, the flipped flag over a pending ledger, unverified coverage under the flag, results outside the supported set, malformed covered decisions and the main-entry exit codes; disabling the audit-flag branch fails exactly the flag rows. This is the verifier boundary only — producing bundles from actual port-suite executions stays with the release-qualification work in #44.
- Complete the M1 drift tool with the reviewed-pin advancement flow (#51): `drift.py` gains the pin flow the classifier core left open. With `--pins`, `--new-revision` and `--archive`, the observed tree is bound to its claimed revision before any bookkeeping is written — the candidate archive is digested, extracted and required to match the compared tree byte for byte (`same_tree`, tar `data` filter, exact root name), so a mismatched tree, root-drifted archive or non-40-hex revision is a tooling error with pins.json byte-identical and no report on disk. Without `--advance` the run only records the observation under `sources[name].review` (`observed_revision`, `observed_on`, report and archive digests); with `--advance` it additionally rewrites the pin — `revision`, the codeload archive URL with the new digest, and the derived root — records `advanced_from`/`advanced_on`, and stamps every changed path plus the report header with direct commit links. The pins rewrite is atomic — the report file is written only after the bookkeeping succeeds, so a failed advancement never leaves a report describing an unrecorded observation — and every recorded revision/date/digest field plus the bookkeeping object's type is validated by `fetch.load_manifest`, so malformed bookkeeping fails the next manifest load; `--advance` without the complete pin-flow flag set is a named refusal, never a silent no-op. The report is the review evidence, not the approval: an advanced pin merges only after a full oracle requalification run against it (Reference Baseline runs the complete differential on every pins.json change) and a reviewed `requires_review` list, and the weekly observation cadence stays in M2. The data-driven suite covers observation-only bookkeeping (pin untouched, digests bound, no `advanced_from`), the full advancement (manifest reloads cleanly through the real loader), five hostile refusal shapes (tree exceeding archive, archive root drift, content mismatch, malformed revision, unknown source — each leaving pins byte-identical and no report), an oversized compared tree refusing before any write, incomplete flag sets including bare `--advance`, and malformed recorded bookkeeping failing the manifest load; replacing the binding call with a bare digest fails the refusal shapes.
- Wrap the ring-wrap flood under heterogeneous per-peer construction delays (#34, #59): the two new delay profiles carry the #372 construction-delay axis through the #378/#380 total-silence flood — `mesh_3_wrap_flood_delays_2_1_0` holds the delay band's three distinct extremes across a three-peer mesh and `mesh_4_wrap_flood_delays_2_0` interleaves the extremes across four peers — so every machine wraps its default 128-row ring (at least 129 confirmed boundaries per peer) while its delayed early samples stay stamped, compared and confirmed end to end through the deep LOAD heal. The wrap harness's profile table gains the per-case delay list as a fifth field, the builder stamps `delays` into the scenario without changing its one-frame-per-round model (the builder's per-round model checks still fail the regeneration on divergence), the fixture loader refuses delay drift beside its digest, window and count/capacity checks, and the evidence gate binds the profile identity including the delays. Both pinned engines match the pinned upstream twice per side with raw compression validation, fresh-process repeats, per-machine wrap receipts and all seven wrap controls.
- Classify upstream drift between pinned source trees (#51, M1): the new `scripts/reference/drift.py` compares a last-reviewed tree against a latest-observed tree of one pinned source and produces the machine-readable and human reports the task requires. Every changed path lands in one reviewed category (production source, tests/models/fixtures, dependencies, build logic, documentation), Rust diffs narrow into conservative signals (whitespace/comment-only, constants/statics, attributes/macros, cfg gates) through a real line-level diff, same-content add/delete pairs report as renames instead of churn, and each path maps onto its parity-ledger decision with unmapped paths named. The classifier never claims semantic equivalence: the noise verdict is only blanks, whole-line comments and per-line whitespace differences in source order — string-literal contents and statement order are always semantic — every other change lands in `requires_review` whatever its category, a rename gates unconditionally because the path is the ledger key, unmatched paths fail closed, and a missing, unreadable or bounded-out input (file-count or byte bound) is a tooling error with a nonzero exit instead of a no-drift report. The data-driven suite covers every synthetic shape issue #51 lists — whitespace/comment, constant, attribute, cfg, build script, dependency-only, test/model-only, docs, mixed, addition, deletion, rename, ledger mapping and unmapped fail-closed — plus the hostile shapes review surfaced (a changed URL inside a string, swapped statements, an oversized file, duplicate rename candidates) and missing-tree, walk-bound, unreadable-file and git-directory input controls. This delivers the classification and impact-mapping core of M1; the weekly reporting workflow stays in M2.

- Pin the ring-wrap flood at the deepest supported prediction window (#34, #59): the new `mesh_4_wrap_flood_window_8` corpus case runs the same four-peer total-silence flood, reversed duplicate-carrying release and default 128-row ring wrap at prediction window eight, so the wrap axis is held at both the family window four and the boundary window eight in one committed fixture. The wrap harness's profile table now carries each case's window, the fixture loader refuses window drift beside its digest and profile checks, and the single-fixture regeneration path rebuilds one schedule into the existing manifest without rewriting the rest. The measured case schedules 3924 operations and 3362 packets; the deeper stall cap (`frontier + 8`) heals through a measured seven-row LOAD correction, every peer confirms 138 canonical boundaries, and the seven existing wrap controls all fail at their declared diagnostics. Both pinned engines match the pinned upstream twice per side with raw compression validation, fresh-process repeats and the per-machine wrap receipt.
- Reconcile the stale open-requirements claim in the asymmetric queue-wrap guide section: the global-floor reclamation, retained-floor side slot and floor-mutant evidence now points at the delivered session-engine differential (`sync-floor-probes`, PR #358) and the partition/heal/fairness lifecycle cases instead of describing closed #61 requirements as open.

- Extend the ring-wrap flood corpus to every supported count at the production default ring (#379): `mesh_3_wrap_flood`, `mesh_5_wrap_flood`, `mesh_6_wrap_flood`, `mesh_7_wrap_flood` and a default-capacity `mesh_8_wrap_flood` join counts two and four in climbing past the default 128-row queue under the same six-round total-silence flood and reversed duplicate-carrying release, and the eight-peer 32-row case keeps its full-fanout scale point as the renamed `mesh_8_wrap_flood_32`. Reaching 129 confirmed boundaries at the eight-peer fanout needs 16324 scheduled operations at the measured profile, so the oracle's scenario-operation bound rises deliberately from 10000 to 20000 in all three validators (the Rust oracle, the Python contract and the Godot trace driver) — still a denial-of-service guard, not a corpus limit — with hostile tests pinning the exact boundary on all three validators and on both raw-trace guards, and the oracle binary's and the standalone validator's raw-trace stdin guard follows the seven- and eight-peer default traces (18.2 and 25.9 megabytes spaced) from sixteen to thirty-two megabytes. The built schedules land as committed fixtures with digest provenance, so CI loads them instead of rerunning the builder's quadratic per-round replays (the measured cost first blew the merge queue's 30-minute check-response timeout at 43 grouped-candidate minutes), and a dedicated wave launcher runs the wrap corpus beside the rest of the P2P family; the regeneration tool and every launch-time gate keep the fixtures bound to the pinned binary. The Reference Baseline oracle wave keeps 45-minute headroom for slow runners. Both pinned engines match the pinned upstream twice per side with raw compression validation over each whole trace, receipts record per-machine wrap evidence at every count, and docs/oracle-p2p.md stops calling the counts five-through-seven rows open. This closes #379's remaining long-ring-wrap acceptance and advances #59 and #34.
- Compare long ring-wrap runs under a withheld multi-round flood through the P2P oracle: the new `mesh_2_wrap_flood`, `mesh_4_wrap_flood` and `mesh_8_wrap_flood` corpus cases hold real queue rings while six rounds of total silence — inputs and acknowledgements alike, on every link — freeze each confirmed frontier and drive every machine into its prediction limit, where it stalls silently exactly as the pinned source does (the shared normalization names those steps `PREDICTION_STALL` on both sides); the release is the flood, one reversed back-to-back burst with the newest withheld inputs re-delivered as duplicates, and the heal runs through a deep LOAD correction that re-runs the starved stretch from actual inputs before normal confirmation resumes past the ring's capacity. Counts two and four wrap the production default 128-row ring (at least 129 confirmed boundaries per peer); the eight-peer full mesh emits fourteen packets per peer per round, so a default-capacity wrap there would exceed the oracle's 10000-operation scenario bound and that scale point instead wraps a 32-row ring at the full fanout, the frontier passing the whole ring and climbing past it. The builder derives each step's payload from the machine's observed frame — a stalled step reschedules its current frame, so repeated stalled samples stay byte-identical — and re-verifies that model against every observation, failing the build instead of shipping an inconsistent schedule. The receipt requires, per side, a release run — the deliver run ending at the last duplicated re-delivery — of at least the withheld stretch's own input share, the duplicated deliveries themselves, per-machine predicted advances and silent stalls (at least one of each on every machine), a correction of at least three rows from one LOAD and every peer's confirmed boundary count past its ring's capacity; controls clamp every confirmed frontier below the capacity, remove the correction LOADs, rename the stall diagnostics while advancing their frames and hide one machine's predictions or stalls while every aggregate stays large, each failing at its declared diagnostic. The four- and eight-peer raw traces exceeded the oracle binary's and the standalone validator's old four-megabyte stdin guard, now raised to sixteen megabytes — a denial-of-service bound, not a corpus limit. Both pinned engines match the pinned upstream twice in fresh processes with raw compression validation over each whole trace. This delivers the long ring-wrap and bounded-flood slice of #34's and #59's remaining acceptance.
- Document the external-review-availability policy in the harness (#307): external automatic reviewers can pause or skip after reviewed commits, or stay unavailable for service or billing reasons, so the ship-session flow and the session contract now state that such a check is recorded as unavailable coverage — never a clean review result, kept distinct from CI workload failures — while the review of record remains a fresh-context adversarial review plus the complete post-green feedback scan. Requesting a bot review explicitly or changing repository/service settings stays out of scope.

- Gate every merge through a merge queue: a `main merge queue and protection` branch ruleset requires the four Gate checks plus a single new `Qualification summary` context on each grouped merge candidate, allows merges only through the queue (squash method, HEADGREEN grouping, 30-minute check-response timeout, deletion and non-fast-forward protections, no bypass actors), and blocks direct pushes to `main`. The Gate workflow gained the `merge_group` trigger and the merge-group base SHA in both base-resolution jobs, because the queue builds grouped candidates whose required checks must report or every entry would hang. The Reference Baseline workflow runs unconditionally on merge-queue groups and no longer runs on pushes to `main`, so the group run replaces the post-merge qualification and `main` is green by construction; its new summary job needs all five qualification job families and fails when any family failed or was cancelled, giving the queue one stable required context instead of 32 fragile per-job display names. The ship-session skill and GOAL.md merge flow switch to `gh pr merge --squash --auto` with cheap `gh pr view` polls instead of `gh run watch`, whose aggressive polling exhausted the API rate limit during enablement. Commissioned in #368; the ruleset composition is pinned by the workflow-tier contract tests.
- Split continuous integration into three tiers so every gate still runs somewhere while the per-push path gets fast again: the new Gate workflow runs on every push and pull request (harness checks, a changed-suite unit run on the minimum pinned engine through the fail-closed `--changed` selector, and the reference/oracle negative controls when tooling changes); the Reference Baseline workflow now qualifies only merges to `main` with the full Chromium matrix on both pins (32 jobs instead of the previous 52); and the new Nightly workflow owns the moved axes on a daily schedule — the Firefox ownership matrix and Firefox transport witness plus the SpectatorSession and handshake formal model checks. The handshake launcher gained a `--formal` flag whose `off` value records `formal_skipped` in its receipt instead of silently dropping the model evidence, and the oracle launcher wave forwards it only for the qualify tier; nightly reruns the handshake differential with the model check enabled. Workflow composition is pinned by new red/green contract tests (`scripts/tests/test_workflow_tiers.py`), every package acquisition in every tier keeps its retry wrapper and APT mirror preparation, superseded runs cancel on pull requests (Gate and Devcontainer Verify), and `make gate` gives the session the same pre-push minimum locally that Gate enforces in CI — the harness checks and the changed-suite selection run locally, while the reference and oracle negative controls run in CI only when tooling changes. Motivating measurement: the previous single-tier matrix averaged 10.6 minutes of wall time and roughly 243 minutes of summed job time per push, ran 100 times in six days with a 25 percent failure rate, and pushed sessions into 10-27 CI polls per gate.

### Fixed

- Refuse undecodable flight references in the peer input endpoint: the new wrap-flood delay corpus diverged from the pinned upstream on both engine pins at `mesh_3_wrap_flood_delays_2_1_0`, and the shrinker minimized 2063 scheduled operations to four. Upstream decodes every input flight against the row one frame before its `start_frame` (the zeroed seed when nothing has arrived yet); when peer 2 held only frame 1 and the next flight re-sent that unacknowledged prefix while adding frame 2, its reference row (frame 0) was missing, so upstream staged nothing and re-acked its high-water — while the Godot endpoint staged the newer rows anyway, so its acknowledgement climbed past the reference the source never staged (`ack_frame` 2 vs 1) and the flood release then built on the divergent acknowledged prefix until the compared requests mismatched at operation 24. The endpoint now reproduces the decodability rule exactly: a flight with a received history whose `start_frame - 1` row is missing (frame 0 keeps the NULL-seeded start) is a reference skip — no staging, high-water re-ack, piggyback acknowledgement and status merge consumed, its own trace label — and the shrinker's minimized scenario matches byte-exact on both engine pins after the fix. The new `reference_skip` case in `test_input_endpoint.gd` pins the whole shape (skip, piggyback consumption, unchanged high-water, and the follow-up flight against the held reference staging normally) and fails at exactly its three staging/ack assertions against the pre-fix endpoint, twice per run. The decoder-reference contract is documented in docs/protocol.md.

- Repair the single-fixture wrap regeneration path so it works at all and admits genuinely new profiles: `p2p_wrap_regenerate.py --only` crashed with an UnboundLocalError — the merged #382 squashed the `provenance_path` hoist out, so the `--only` precondition referenced the variable before its assignment — and even with the reference fixed, the precondition demanded a fixture file for every sibling name, making it impossible to regenerate a corpus that gains a new profile without a full quadratic rebuild of all fixtures. The precondition now reads the committed manifest once and verifies only names it actually carries (a manifest-named fixture missing from disk still refuses — `--only` never repairs a committed entry), the post-rewrite verification loop applies the same manifest-carried rule so the first `--only` run of a new profile verifies everything committed and adds itself, the duplicate `digests` initialization is gone, and the delay pass-through joins the window pass-through in the build loop. The regression test drives the real fixture loader over a seeded temp corpus through `main()` with mocked tooling: it pins the named precondition refusal (red against the UnboundLocalError), the missing-committed-fixture refusal, the sibling digest surviving a single-fixture merge, and a loader that fails loudly if the tool ever probes a name the corpus never carried — the mutant with both skip rules removed fails exactly there.

- Name each terminated pid once in the owned-process survivor report (#381): a plain-forked descendant that stays in the session is both a same-group member and a run-token carrier, so when it was still dying inside the SIGKILL delivery race between the two ownership sweeps, both sweeps named it and the merged `members + survivors` report carried the same pid twice — read by callers as two terminations and breaking strict single-survivor unpacks. Reproduced under representative CPU load: the orphan-mode escape case failed 5 of 15 standalone suite iterations under a 32-spinner load while passing standalone between failures, matching the once-per-full-run incident. The group and token sweeps now merge through one order-preserving dedup helper (first sighting wins, group attribution first) at every consumer — the run and split-run escape paths, the interruption cleanup and the spawned-host finish — so no caller sees a pid twice. A data-driven unit test pins the merge contract, fails against the concatenating mutant, and the escaped-descendant test's strict single-entry unpack now holds in both sweep orders; the file passed 15 of 15 loaded iterations and the full reference suite after the fix.

- Retain the npm acquisition-versus-lifecycle evidence of a killed installer (#249): the recurring x64 and arm64 Reference Baseline failures died at an outer build deadline while the merged install stream existed only in the installer's memory, so the failed Docker layer retained no partial output and the stall stayed unlocalized between registry fetching, wrapper postinstall, the native version probe and the nested fallback install. The merged global-install stream is now journaled line by line, redacted and flushed to a fixed per-package path under the system temp directory as npm produces it, so a deadline that kills the installer mid-command leaves the partial evidence on disk and discoverable; complete lines are buffered whole because the redaction regex needs the URL and its query in one piece, an incremental decoder keeps multi-byte sequences whole across read boundaries, the bytes of an unterminated final line are journaled and named in the timeout diagnostic rather than lost, the journal is capped per line and in total at the byte budget, and a hostile or stale file at the path disables journaling with a note instead of breaking the install (the open refuses symlinks and creates the file owner-only; journal open, write and close failures never bypass the timeout handler that owns the process-group cleanup). A healthy install removes the journal it created, and the timeout and failure diagnostics name its path. Latest-release selection, publication-only retries and the existing total and per-command deadlines are unchanged; the post-EOF wait stays inside the caller's remaining budget. The live child tests pin the journal through the process-group timeout and through a hard SIGKILL of the installer mid-install with credentials absent, a planted read-only file pins the disable path, a plain install failure pins retention for the next reader, and the healthy control pins removal on both packages.

- Close the two residual confirmation-frontier re-derivation windows left open by the #374 review (#375): the public `drain_events()` and the refused checksum-report return inside `_service_controls` both ran `_collect_events()`, which can process a coordinated-drop barrier commit — a fold-input mutation — and then returned with no following re-derivation, so the immediately following reported frontier lagged the committed freeze for one read (liveness-conservative only: it never reported above the true fold and re-derived on the next receive, poll or step). Both paths now re-derive the mesh confirmation limit after their collection, under the same running-and-not-terminated guard as every other fold mutation, and the docs sentence names that guard so the docs and the code agree on the exact boundary: a terminated match keeps its last running frontier beside its terminal cause. The `drained_commit_pins_the_frontier` unit case captures the real coordinator COMMIT packet, queues it through the endpoint event seam a receive uses, and pins the certified follower's immediate post-drain frontier read while its departed slot binds the frontier; the `refused_checksum_pins_the_frontier` case drives the same commit through a send-reports service whose checksum report is refused by a full outbox. Every production event producer is drained inline by the same facade call, so both tests queue the decoded barrier at that seam explicitly and their Value lines name it; each case's temporary fold mutant fails at exactly the stale frontier assertion, and both re-derivations stay independent under the other's mutant.

- Reconcile the confirmed frontier after a runtime input-delay raise with the pinned upstream (#373): a raise stamps the local slot to its padded `last_added` frame before the catch-up flight flushes, and upstream folds connect statuses lazily at every read, so its reported frontier counts the stamped slot immediately — while the peer facade's cached mesh confirmation limit only re-derived on the next poll, leaving the reported frontier one poll behind whenever a remote slot had already received confirmed evidence before the raise, exactly the heterogeneous per-peer profile shape. The facade now re-derives the limit after a successful raise and after every service control that can commit a coordinated-drop freeze, which lifts the frozen slot out of the fold and releases its pending ceiling in the same operation; the core still refuses any lowering, so a refused re-derivation keeps the conservative bound. The `raised_frontier` unit case pins the immediate post-raise read, and the P2P oracle restores the profile-plus-raise axis as `mesh_2_delays_2_0_raise` alongside the shrinker's pinned minimized schedule `mesh_2_delays_2_0_raise_min`, each compared twice per side with raw compression validation on both pins; the temporary fold mutant fails at exactly `operation 3: confirmed_frame mismatch`, the issue's pinned first divergence.

- Give each peer its own construction input delay, matching the pinned upstream: the handshake no longer refuses peers that declare different `input_delay` values, because input delay is each endpoint's own schedule, not a session agreement — every other agreed field (input format, snapshot format, checksum algorithm, queue capacity, neutral input, roster and the opaque digest) still refuses exactly as before. The handshake binds each peer's declared delay when the exchange completes; the endpoint accepts that peer's first frame at its declared start instead of the local one, and the session core gains `set_remote_start`, which the peer facade seeds per remote slot just before the peer's first row lands. Sequential rows and the local delay chain keep their exact prior behavior, so every existing fixture and integration is unchanged. New P2P oracle coverage: per-machine scenario `delays` (an omitted field keeps the shared `input_delay`), `mesh_2_delays_2_0` at the band's extremes, `mesh_3_delays_2_1_0_loss` under a frame-zero fault, `mesh_4_delays_2_0_2_0` across the full mesh, and the layout combination `mesh_4_couch_delays_2_0`; the `delays_profile` negative control flips one machine's start against the confirmed neutral prefixes, and the shared process battery pins wrong-length, out-of-band, aliased, null, empty and above-bound profiles on both validators. The red run failed exactly at the old agreement refusal, and a mutant that reuses the local delay as the first-remote-frame expectation fails the mixed case. Both pinned engines match the pinned upstream twice in fresh processes. This delivers the per-peer delay-profile slice of #59's remaining acceptance and the heterogeneous-delay rows of #34 and #33 (#371).

- Compare non-default input widths through the P2P oracle: an optional scenario `input_width` field picks one byte width from the compared representative set {1, 4, 32} (an omitted field stays four bytes, so every existing fixture keeps byte-identical meaning). The Rust adapter becomes generic over the input width and dispatches the configured width at startup, the Godot trace driver configures the peer session, neutral input, codec limits and flight-row slicing from the scenario, and the advance fold — `byte << (8 * (index % 4))` XOR across the row — matches the little-endian u32 read exactly at the default width, so the earlier corpus's arithmetic is unchanged. The Python contract's scenario, step, flight-row and advance reconstruction checks all follow the configured width. New cases: `mesh_2_width_1` at the minimum width, `mesh_4_width_1_loss` under a loss fault, `mesh_4_width_32` with 32-byte rows, and `mesh_8_width_32_window_8` holding the maximum comparable window at the wide width and full mesh size. Wide samples vary every byte deterministically and keep each byte nonzero, so the fold contribution lives in the tail bytes too; `width_row` and `width_tail` negative controls flip a wide row's leading and final byte, and grammar tests pin unsupported widths, wrong-length step payloads and row shapes. Both pinned engines match the pinned upstream twice in fresh processes. This delivers the width slice of #59's remaining acceptance (#365).

- Compare multiple-local-player endpoint layouts through the P2P oracle: an optional scenario `layout` lists how many local slots each machine owns (an omitted layout keeps one slot per endpoint, so every existing fixture keeps its meaning), and step operations address one local slot while deliveries and packet attribution stay per machine address. The pinned upstream builder drives `PlayerType::Local` per owned slot and one remote address per machine, and the Godot peer session receives the matching `local_players` roster. A partially staged machine compares the pinned engine's missing-input refusal — upstream retains its staged local inputs across the failed advance while Godot refuses an incomplete row before staging, so the trace driver buffers earlier step bytes and re-submits them once the machine's coverage completes — and input flights carry one flat row per frame with one four-byte input per owned slot in ascending slot order, validated against the sender's owned-slot list and re-decoded by the raw-compression replay. New cases: `mesh_4_couch_2x2` and `mesh_6_split_2x2x2` ordinary couch and split meshes, `mesh_4_couch_loss` with round-zero packet drops recovered through later batch flights, and `mesh_4_couch_stall`, which withholds the couch machine's flights until the solo machine exhausts its prediction window through the pinned engine's silent stall and then releases them reversed for a rollback-to-zero recovery with both machines converging on the same confirmed frame. Negative controls drop an owned slot from a flight's player list and flip a non-leading input chunk. Runtime delay raises and lifecycle timers stay single-local by contract. Both pinned engines match the pinned upstream twice in fresh processes. This delivers the multi-local endpoint-layout slice of #59's remaining acceptance (#363).

- Minimize a failing P2P differential to its first divergence: when a comparison disagrees, the launcher truncates the submitted schedule at the named operation or packet, then removes remaining operations one at a time while both sides rerun in fresh processes and keep disagreeing. Deliveries stay anchored to the operation that produced their packet — removing a producer also removes its dependent deliveries, and surviving references re-rank against the shortened schedule — a rejected schedule is never probed twice, the probe loop stays under an execution budget, and the minimized scenario is confirmed under the full gates (twice per side with raw compression validation) before the failure raises. The case's output directory keeps the minimized scenario, both confirmed traces and a report with the original and minimized first-divergence messages. This delivers the first-divergence shrinking acceptance in #59.

- Compare the maximum prediction window through the P2P oracle: `mesh_2_window_8`, `mesh_4_window_8` and `mesh_8_window_8` hold ordinary schedules at the deepest supported rollback boundary, and `mesh_2_window_8_stall` runs the schedule that stalls at window four with the window raised to eight, so the six undelivered rounds predict through and recover through one deep rollback instead of stalling at the window-four prediction boundary. Both pinned engines match the pinned upstream twice in fresh processes. This advances the window acceptance in #59 and #34.

- Compare a fair long-lived partition rotation through the P2P oracle: the new `partition_fairness` lifecycle case gives each link of the three-player mesh exactly one starvation turn. A confirmed prefix on all three links opens the schedule, then every turn withholds one link in both directions for six rounds, so both cut endpoints latch their own remote-attributed `network_interrupted` past the shared notify bound while the third peer keeps both of its links alive. The withheld burst arrives inside the disconnect timeout: exactly the two cut endpoints observe `network_resumed`, the missing inputs force deep LOAD corrections through the public advance API, and three confirmed rounds re-synchronize the mesh before the next link takes its turn. After all three rotations the tail rounds and polls end the schedule synchronized with no terminal on any peer — no link, and no peer, is treated differently by the schedule. Both pinned engines match the pinned upstream's ordered requests, events, gauges and canonical states twice in fresh processes; the builder requires both attributed latches and exactly two resumes per rotation, and requires no further resume through the tail; controls mutate the notify payload, remove a resume event and retarget an attributed event peer into a self-interruption. This extends the long-lived partition/fairness acceptance in #59 and #61.

- Compare a healing one-way partition through the P2P oracle: after a confirmed prefix, the new `partition_heal` lifecycle case starves peer 1 of every peer-0 packet past the notify bound, keeps peer 1 predicting through six withheld rounds, then delivers the entire withheld burst well below the disconnect timeout. The burst fires `network_resumed` and forces a deep LOAD correction through the public advance API; the schedule then re-delivers the first withheld report on purpose, so peer 1 answers the same echoed token twice and peer 0 re-measures that duplicate against its current clock exactly as the pinned oracle does, before three more confirmed rounds end the schedule synchronized with no terminal. Named receipt evidence requires the interruptions, the resume, the recovery LOADs and one per-sender duplicate echo; controls mutate the notify payload and remove the resume event. This advances the partition/healing acceptance in #59 and #61.

- Compare a healing three-player partial partition through the P2P oracle: the new `partition_heal_mesh` lifecycle case confirms a real prefix on every link, then cuts the direct 1<->2 link in both directions while both cut peers keep their links to peer 0. Each cut endpoint latches its own remote-attributed `network_interrupted` past the shared notify bound — the attributed event peer is the departed remote, not the observer — and both cut peers predict through six withheld rounds on their surviving links while peer 0 keeps both of its links alive. The withheld burst then arrives inside the disconnect timeout: both cut endpoints observe `network_resumed`, the missing inputs force deep LOAD corrections through the public advance API, and three more confirmed rounds end the schedule synchronized with no terminal on any peer. Named receipt evidence requires both attributed interruptions, both resumes and the recovery LOADs; controls mutate the notify payload, remove a resume event and retarget an attributed event peer into a self-interruption. This extends the partition/healing acceptance in #59 and #61 to the mesh setting.

- Compare the shared session engine's global rollback floor against the pinned SyncLayer: the new sync-floor oracle drives the `tests/unit/test_rollback.gd::global_floor` schedule — three players, prediction window four, capacity nine, a fast queue receiving ahead of the session, a three-frame lagger and a delay raise during active prediction — through both engines in fresh processes twice per pin. Every ordered save/load/advance request and canonical state, every recorded acceptance or refusal (the above-floor add, retained floor repeats, the stale floor after the advance), and the floor, retained-range, confirmed-floor and recoverable-floor observations must match exactly, and the final resimulation of every confirmed frame must equal an independent original-input history. The pinned crate compiles from a verified isolated copy carrying access-only wrappers; a mutant build that replaces the global floor with the fast player's local high-water must accept the above-floor add the clean floor refuses at the frame-twelve boundary, the comparison's first divergence. This delivers the session-level floor, occupancy and tag observation slice of #61; actual P2P transport observations stay open there and in #59.

- Compare an explicit non-power-of-two queue profile through the P2P differential oracle: `mesh_3_capacity9_late_flight` builds both adapters' rings from a nine-row scenario capacity, withholds peer 2's flight for ten rounds so slot-2 corrections stay pending at the starved receiver, then forces one deep correction through the released rows and requires three confirmed wraps of the ring on every peer. Runtime delay changes now compare at the capacity-aware bounds, modeled exactly as production computes them — the strict contract also rejects profiles the peer session would refuse to configure — and the only comparable raise at capacity nine is one both implementations refuse. The case documents why public peer scheduling cannot witness full-capacity occupancy: producer frontiers mutually freeze within their prediction windows, so the session-level floor, occupancy and tag observations stay open in #61 as an access-only SyncLayer slice.

### Fixed

- Decode the pinned P2P oracle's compressed flights against the exact upstream reference contract: every flight row XOR-deltas against the destination's last-ACKED row, flights join the sender's pending queue at creation, and a carried `ack_frame` pops the receiving endpoint's own pending rows when the packet is delivered rather than when it is created. The old previous-frame approximation silently mis-decoded un-acked multi-frame flights (a two-row flight decoded to stale rows instead of the submitted samples) while both engines' errors coincided on immediate-ack two-player schedules; the second source-process validation now replays the scenario operations and re-decodes at delivery-time references.

- Publish each trace operation's outgoing packets in the pinned shared-socket order: a step first flushes every endpoint's queued controls, then publishes each endpoint's checksum reports with that step's own input flight. The trace driver previously concatenated per-endpoint queues, interleaving controls with inputs across endpoints, so no multi-peer lifecycle schedule could compare at all.

- Resolve quality-reply RTT statelessly from the echoed elapsed-millis token, matching the pinned upstream: the reply handler no longer keeps a pending-token inventory, so a duplicated, reordered or stale-era echo re-measures against the current clock instead of silently freezing the gauge at the last retained token — the divergence the new partition-heal differential caught once its deliberately re-delivered withheld report made the starved peer answer the same token twice. A pong wider than the clock range measures a harmless zero, exactly like the upstream saturating subtraction. The port-only `max_pending_quality` lifecycle option is removed; peers that pinned it must drop the field when upgrading.

- Require an independent departure witness before an automatic timeout drop certificate commits: a fellow survivor must attest, in its window report and again in its certificate, that its own endpoint for the target latched the departure. The coordinator re-checks the certificate's attestation against the report's and ends the match with `missing_witness` (or `conflicting_history` on a disagreement) instead of freezing on an unwitnessed certificate. Goodbye and explicit departures keep their path, and the strict-majority quorum gate is unchanged. The attestation rides the `DROP_BARRIER` report's former reserved trailer byte, which now decodes only `0` and `1`; a peer built before this change refuses such packets, so upgrade all match participants together.

### Improved

- Witness the group-kill descendant tests with a held pipe write end instead of a `/proc` zombie poll: the read end returns EOF exactly when the launcher leader and its fork have both exited, while a reaped entry or a reused pid could make the old poll name a survivor for a group the kernel killed. A partial group kill (leader only) fails the new witness at its own diagnostic; the 218-test harness suite passes twice in fresh processes.

- Scope the probe wave's host-lease inheritance to the wave owner's identity instead of its lease name: the wave owner publishes its name and pid through `FORTRESS_HOST_LEASE_HELD`, and a member inherits only while the live lease record names that exact owner, not by the name alone.

- Acknowledge the spectator pages' own completed `/viewer` control POST beside an intended admission rejection as the same `net::ERR_ABORTED` result-phase disposal artifact already acknowledged beside a passing `/done` result, and run the acknowledgment in the admission-rejection cells. The pairing still requires exactly one origin-bound result-phase artifact, no runner failure, a page-level error-free report, and either a passing page or the demonstrated refused-state decision with zero simulations; a page that failed a playback step mid-run stays fatal. This repairs the merge-triggered `initial-state` witness failure on main.

- Capture each repository-harness command's output in the devcontainer verification and print its tail when the check rejects the environment, so a failing check names its own failure instead of leaving the rejection to blind reproduction.

- Overlap the online leg's seven native probes (relay witness, native spectator witness, two departure cells and three late-signal cells) in one bounded two-worker wave with fail-closed aggregation, cutting the Reference Baseline wall-time critical path. The host-capacity lease is held once for the whole wave and the probe children inherit it, so no two probe processes contend; every probe keeps its exact command, watchdogs and output paths, the six browser-viewer cells stay serial, and every failure still names its own log without masking a sibling.

- Acknowledge exactly one success-paired disposal artifact in the exported spectator witness: the viewer page's own completed `/done` control POST that the pinned web transport reports as `net::ERR_ABORTED` during result-phase bookkeeping. The observation stays in the receipt under `acknowledged_disposal_abort`, the pairing requires the page's passing result and the exact six-field failure identity, and every other browser request failure stays fatal. This ends the intermittent host-departure witness failure that issue #322 diagnosed.

- Name each example's stopped cause in plain language, keeping the numeric code beside it for tooling. Session reasons render through the shared `FortressSessionTypes.reason_text()` helper in the offline, effects, peer, online, spectator, replay-viewer and diagnostic-viewer labels and refusal messages; the peer example's packet-failure line keeps its own wording for the separate protocol endpoint enum.

- Name the online example's protocol and transport stop codes in plain language beside their numbers: the endpoint codes render through the shared `FortressInputEndpointTypes.reason_text()` and the relay/fallback transport codes through the shared `FortressSignalFishRelayTypes.reason_text()`; the peer example's failure line now reuses the endpoint helper instead of duplicating its own enum wording.

- Pair neighboring Firefox ownership suites into shared browser pages when the same runner's measured native suite cost fits the hosted page deadline, with the peer-parity suite still one case per page. A hosted Firefox part ran 14 pages in 217s instead of 25 pages in 415s, with every case, repetition and comparison unchanged.

- Share one npm download cache across the browser CI jobs, so repeated `npm ci` installs stop fetching every package from the registry.

### Added

- Compare an actual one-way partition through the P2P oracle: after three confirmed frames, the new `partition_one_way` lifecycle case drops every packet from one peer while delivering all of the other's. The starved peer predicts through the loss, both peers latch their own `network_interrupted` once quiet spans pass the shared notify bound, and the schedule ends at the starved peer's terminal poll. Both pinned engines match ordered requests, stalls, gauges, canonical states and the single final terminal twice in fresh processes, with the case's required observations and mutation controls recorded in the receipt.

- Overlap the ownership witness's per-suite native engine processes in a bounded wave. Each suite keeps its own fresh process, 180-second watchdog and after-run boundary verification; the wave joins every suite and a rejection still names the first failing suite in suite order. The native-only 4.3 part-1 witness finishes in about 2m38s locally instead of 9m41s.

- Stream npm lifecycle and registry-phase evidence during native CLI installation (`--foreground-scripts --loglevel=http`), so a hung global install localizes to wrapper postinstall versus registry acquisition on the next failure.

- Run the oracle launchers (queue, development oracle, replay, handshake, p2p, drop history) in bounded parallel subprocesses with fail-closed aggregation in the oracles CI leg. Each launcher keeps its own interpreter, output directory and receipt; the shared pinned cargo target stays correct under cargo's own build lock.

- Run each Chromium ownership phase as its own workflow job (negative/positive per engine pin and suite part), matching the Firefox matrix shape.

- Bind the native test receipt to the on-disk Python helper bytes. The launcher digests its own script and every helper module it executes after they have loaded and before starting an engine, re-verifies them after execution and reports helper drift as a failed qualification instead of a stale success.

- Run the oracle negative-control suite through the same bounded parallel subprocess runner as the reference suite. Oracle test files are now import-order independent, and the suite finishes in about 42s locally instead of 63s.

- Run the reference negative-control suite through bounded parallel subprocesses with fail-closed aggregation. The same cases now finish in about 3m21s locally instead of 8m49s; the ownership rejection suite is split by concern into four files.

- Add pause, resume and single-frame controls to the effects replay. Focus loss holds playback until explicit resume.

- Add peer-example buttons and F/G shortcuts to apply fresh measured input-delay suggestions.

- Add S/F replay shortcuts for slower/faster playback, with the accepted rate shown in the speed selector.

- Keep spectator-example controls readable in short windows with scrolling and separately fitted game views.

- Add a replay inspection pause when opening the file chooser. Canceling keeps the current recording paused until explicit Play.

- Add focus-loss pause to the effects match and replay viewer. Resume explicitly; selected replay seeks still finish paused.

- Add Finish match to the effects demo. Confirm pending inputs and preserve final effects before watching the complete replay.

- Add replay selection markers to repeat a chosen frame range with checksum validation.

- Add a whole-demo pause to the spectator example. Focus loss freezes host, delivery and viewing until explicit resume.

- Add owned neutral input bytes on the driver and expert session so clients can build input rows without retaining configuration.

- Add driver local-player discovery in the byte-only input submission order.

- Add replay shortcuts for previous/next input changes and recorded checksums.

- Add automatic focus-loss pause to local offline and two-peer examples. Resume explicitly to continue.

- Add pause and single-tick controls to offline and two-peer examples, including packet-service inspection.

- Add pointer controls for peer-example packet faults, input delays and reset.

- Add player selection to replay input and status change navigation.

- Add single-tick host inspection to the spectator example while preserving independent viewer playback.

- Add pause and single-tick inspection to the playable effects example, including delayed delivery, rollback and confirmed effects.

- Add independent host pause to the spectator example. Pending inputs settle while viewers continue watching.

- Add replay Repeat playback. Each lap starts from the initial state and checks original evidence; playback failures stop repetition.

- Add delay, replay and restart buttons to the effects example, with movement focus preserved.

- Add host input delivery controls and 1/2/3 shortcuts to the local spectator to explore prediction stalls and buffering independently of viewing delay.

- Add Enter-to-go in the replay frame field. Accepted navigation restores playback shortcuts; refused navigation preserves editing focus.

- Add `driver.step_local()` to submit local input bytes without constructing player/frame wrappers.

- Add readable spectator stop reasons, including failed game callbacks and their frames.

- Add a replay status-only filter to inspect player disconnects without stopping at every control change.

- Add online buttons to raise input delay or apply the current suggestion.

- Add a Lose host link button to the local spectator, including during unfinished playback requests.

- Add five-second and start/end replay jumps, with keyboard shortcuts and bounded checksum-validated navigation.

- Add a Save viewed replay button to the local spectator, including retained recordings after viewing stops.

- Add an exact frame and time preview while dragging the replay timeline. The displayed game and checksum status stay at their current frame.

- Add End host and Restart match buttons to the local spectator, including recovery after host loss or completed playback.

- Add a replay Validate state control to check a paused boundary without advancing input. Missing recorded checksums remain explicitly unverified.

- Add pointer controls for spectator viewing delay and catch-up speed, with limits and playback readiness shown on each button.

- Add pointer controls for single-frame spectator stepping and one-time bounded catch-up.

- Add replay provenance during inspection, with wrapping hover details for engine, game, seed and source revisions.

- Add a Pause/Resume button to the local spectator, with the same readiness checks as its keyboard control.

- Add replay prefix downloads at the displayed frame, preserving original inputs, metadata and recorded checksum evidence.

- Add Follow live to resume the local spectator at the latest received input through bounded catch-up.

- Add native replay file drops with bounded validation and preservation of the current recording after refused imports.

- Add spectator input-buffer capacity observations and a resume/catch-up prompt when paused input fills the buffer.

- Add a draggable replay timeline with elapsed and total recorded time. Selection uses bounded, verified navigation and finishes paused.

- Add C to catch the local spectator up through currently buffered rows, preserving its viewing delay and normal catch-up rate.

- Add spectator replay progress and a warning before its recording limit. Continued viewing shows omitted frames and explains where the saved replay ends.

- Add recording progress through session, driver and peer APIs. The online example shows finalized, pending and omitted gameplay at the recording limit.

- Add spectator host observations for liveness, remaining timeout and missing final rows, including through the SignalFish viewer adapter.

- Add `DiagnosticPlayer.terminate()` to cancel captured-window playback, expire active views and preserve earlier failure evidence.

- Add spectator backlog feedback during pause and playback. Show contiguous buffered input separately from later rows waiting beyond gaps.

- Add saved spectator-example playback in the replay viewer, including checksum validation, Fire input inspection and backward navigation. New exports identify their game; older unnamed exports remain refused.

- Add comma/period spectator catch-up controls. Adjust the bounded frames-per-tick limit while preserving viewing delay and pause.

- Add Previous/Next recorded checksum replay controls. Inspect sparse verification boundaries and recorded final states through verified navigation.

- Add spectator viewing-delay controls with [ and ]. Adjust the confirmed-frame cushion without restarting or rewinding playback.

- Add spectator missing-frame and pending-input observations. Buffering feedback names the gap and later rows already received.

- Add Previous/Next input change replay controls, including confirmed or disconnected status changes, with verified navigation.

- Add owned spectator playback status separating missing input, viewing delay, final tails and completed or stopped playback.

- Add `FrameInputs.input_status(player)` to read applied player status alongside reusable input buffers without creating an owned result.

- Add failed callback names and frames to diagnostic downloads and the offline viewer.

- Add replay input inspection showing the selected frame's recorded directions and confirmed or disconnected player statuses. Corrupt input rows are identified without displaying their values.

- Add keyboard replay inspection: P plays or pauses, N/B step forward/backward, R restarts, and Esc cancels a seek. Text entry and file chooser input remain available.

- Add empty and partial peer input retries using retained local samples. Callback and expert clients can resume stalled publication without rebuilding submitted inputs.

- Add `peer.confirmed_inputs(frame)` for owned finalized input rows. Network clients can drive confirmed effects and spectator publication without enabling recording.

- Add final replay checkpoints after successful terminal-state validation. Return to the verified ending after backward inspection without replaying the tail; checkpoint memory stays bounded.

- Add spectator example replay export with V. Save viewed history and its captured final state, including clean empty matches; recording retains the first ten minutes.

- Add replay selected-state checksum status to the player API and viewer. Paused inspection distinguishes matching, unchecked and absent recorded checksums.

- Add `SnapshotReader.read_into(destination)` to reuse small fixed-width buffers without creating read-result wrappers. Wide snapshots can keep faster native `read_bytes()` copies.

- Add state-bound spectator configuration digests so startup rejects different canonical initial worlds, even with matching seeds and rules.

- Add manual peer request batches without requiring game callbacks, including recovery and final replay capture.

- Add replay final-state validation status and explicit viewer completion messages distinguishing final-state checks from historical checksum coverage.

- Add final-state replay capture to peer sessions and the online example. Press Finish replay before leaving, then download after confirmation to verify the last simulated input.

- Add explicit final replay checksum capture and FRRP v6 playback. Capture after confirmation and recovery to detect differences caused by the last input; existing v4/v5 files remain readable.

- Add owned retained-input reads to peer sessions so clients can retry stalled steps without resampling local input.

- Add replay callback failure kinds to the player, viewer and failure downloads, identifying failed SAVE, LOAD and ADVANCE callbacks.

- Add replay comparison labels to the player API, viewer and failure downloads. Input digest failures are distinct from game-state and restored-checkpoint mismatches.

- Add a bounded SignalFish spectator host publisher with exact-byte send retries and authenticated viewer acceptance. Live exported relay qualification remains pending.

- Add replay failure downloads with the recording fingerprint, comparison hashes and observed game state for diagnosis.

- Add `FortressDriver.diagnostic_trace()` to export owned opt-in canonical evidence after callback failures without retaining the expert session.

- Add failed callback kinds to driver and peer step/recovery results, preserving the first failure through later calls.

- Add retained replay checkpoint listings and Previous/Next checkpoint viewer controls for paused inspection.

- Add an L control to demonstrate spectator host-link loss, stop buffered viewing immediately, and restart with R while the host keeps playing.

- Add bounded expert replay checkpoint navigation through `begin_restore_before()`, with ordered load and save validation before selecting the restored frame.

- Add `FortressReplayPlayer.begin_validate_current_frame()` so expert clients can validate paused inputs and state without advancing playback.

- Add an optional authenticated spectator startup control callback. Refused acceptance packets retain exact bytes for retry; host agreement still requires actual delivery.

- Add `FortressDriver.terminate()` so driver-only clients can stop a session, including from game callbacks.

- Add driver access to retained local samples and input-delay controls. Standalone clients can retry stalls without resampling; networked clients must still change delay through the peer session.

- Add bounded SignalFish spectator ingress with authenticated host filtering and strict lifetime expiry. This receive-only bridge requires separate startup acceptance; live Fortress relay support remains unqualified.

- Add `FortressDriver.confirmed_inputs(frame)` and `replay()` for finalized inputs and owned match recordings without retaining the expert session.

- Add bounded donor recovery during graceful peer drop. Survivors transfer missing actual inputs before certification and preserve confirmed history. **Breaking:** upgrade all match participants together for the new handshake feature.

- Add finalized player statuses to spectator playback. Dropped matches retain `DISCONNECTED` in callbacks and confirmed exports. The authenticated envelope moves to v3; update host and viewer together. Byte-only callers keep all-confirmed defaults.

- Report an aborted test case in the engine result. A case that dies inside a nested helper no longer looks green: on the Godot 4.7.2 pin the runner sees the script error and fails the case with the aborting file, line and message. The entry belongs to the repetition that died, and an error in a suite constructor fails the case that was being prepared. Godot 4.3 cannot observe a script error in process, so its engine result keeps the engine's own verdict and the Python launcher stays the gate there. The runner prints the capability of its engine, so a release never claims an engine result that only one pin provides.

- Keep an online match alive when a rollback correction withholds a checksum. The mesh checksum scheduler treated a snapshot that a pending repair withheld as a lost history, so a normal prediction correction ended the match with `HISTORY_UNAVAILABLE` one advance before the repair could finish. The scheduler now waits for the repair and publishes the boundary after it. A snapshot that no repair will restore still ends the match, so a real loss is not hidden behind the wait.

- Publish the supported features. A new [supported features](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/blob/main/docs/supported.md) page states the supported Godot versions, browsers, player counts, transports and game-facing features, and lists the features that are deliberately not supported yet with the issue that owns each one.

- Prove the coordinated drop with two survivors in one session. Three real peer sessions now run the barrier end to end: one peer stops answering, the two survivors notice the silence, agree one frame, publish the drop and keep one confirmed history while they keep playing, and a second departure leaves one survivor that freezes the slot on its own frontier and keeps the match running.

- Certify the frozen value of a departed player. The survivors of a match now agree on one frame and one value for the departed slot: every survivor reports the frames it still holds, the survivor that proposes the cut sends the value to the survivors that already released it, and every survivor certifies that value before the departure is committed. A survivor that certifies another value ends the match with the recorded reason `conflicting_history` instead of freezing different bytes for the same frame.

- Agree the frozen frame when a player leaves. With `disconnect_behavior = CONTINUE` and more than one survivor left, the survivors exchange their freezable frame windows and freeze the departed slot at one common frame, so they keep the same confirmed history instead of splitting at their own frontiers. The match holds while the survivors agree, the agreement is bounded by `drop_barrier_timeout_us`, and a barrier that cannot agree reports `peer_drop_unconfirmed` and falls back to the survivor's own frontier.

- Negotiate the spectator envelope before the first row. The host offers the envelope version and the optional kinds it can publish, the viewer answers with the version it can speak, and the two sides refuse each other at startup with one recorded reason when they cannot agree. A viewer that only speaks version 1 now fails before it plays anything, and a host without an agreement publishes no row.

- Authenticate the spectator byte envelope. Every packet now carries a keyed tag and the digest of the agreed match, so a viewer accepts only the host and the match it agreed with. The envelope version moves from 1 to 2.

- Keep the match running when a player leaves. Set `disconnect_behavior = CONTINUE` on the peer lifecycle options and a departed player's slot is frozen at the frame the mesh had confirmed. The survivors keep playing, the departed input repeats its last confirmed value and reports a `DISCONNECTED` status, and the confirmed history before that frame never changes. The default policy still ends the match when a peer stops answering.

- Report the progress of every test case with the time it took. The runner measures each case with an injected clock: a deterministic tick clock in the native runner, the real host clock in the exported browser host. A rejected browser run names the last completed case and the case in flight.

- Copy snapshot bytes with one native append instead of one interpreted step per byte. A game that saves 4 KiB of state per frame now spends about 3 microseconds on the write instead of about 60, and the writer no longer reserves its full capacity up front. The saved bytes, the overflow behavior and the caller-owned copy are unchanged.

- Add `driver.status()` and `driver.statistics()`. A client that only holds the driver now reads the current frame, the confirmed frame, the lifecycle and the counters.

- Add the session's terminal `reason` and `failure_frame` to every driver and peer step result. A desync or a callback failure is no longer reported as a plain stop.

- Add `replay.matches_config()` and a configuration argument to the replay player. A recording from another roster, sample width, neutral input, seed or version is refused with `INCOMPATIBLE_RECORDING`.

- Add `player.skipped_frames()`. A recording whose input was substituted is no longer mistaken for a faithful copy of the original match.

- Keep the viewer's playback policy when a spectator stream is reconfigured. A policy that no longer fits the new ring falls back to the session defaults.


- Add transport traffic reporting. `poll()` results now carry `activity`, the number of transport items taken off the wire, refused ones included, and the direct, relay and composed adapters expose `idle()`.

- Stop the online example's service batch once the transport is idle. A busy or refused route keeps the whole bounded batch, so a slow link still drains while an idle page stops spending its frame budget on repeated polls.

- Add explicit local ownership of the shared reference cache. A second local probe reports who owns the cache instead of deleting the first run's logs.

- Add `make prune`, `make prune-apply`, `make disk` and `make scratch` to keep the machine-local caches and scratch bounded. The pruner never removes a path a tracked file names, never removes a tree a running session still holds, and a dry run is the default.

- Add a scratch-copy helper at `scripts/scratch_workspace.py`. It skips `.cache/`, `.git`, `.godot` and `progress/`, so an isolated run no longer copies the whole cache with the tree.

- Add a disk budget to the devcontainer acceptance harness. `verify.sh` reports the repository cache and container scratch sizes and fails above 25 GB and 20 GB. The reading keeps the size `du` reported when part of the tree could not be read.

- Add expert replay requests through `FortressReplayPlayer.configure_expert()`. Dispatch the same ordered saves and advances used by callback playback.

- Add N-key single-frame inspection to the spectator example. It preserves viewing delay and pause, and can drain a clean final tail.

- Add `FrameInputs.player_count()` and `read_into()` for reusable fixed-width input buffers. Use `read()` when you need input status or prefer bulk copies for wide samples.

- Add typed spectator playback events for waiting, contiguous host input, clean host closure and terminal completion or failure. Driver results carry events after callbacks finish.

- Add replay checksum coverage to the viewer. Recordings without checksums clearly report that playback could not be verified.

- Add bounded final receipt gossip to explicit peer recovery. A mesh can confirm its last simulated inputs after sampling stops, including when a final gossip packet is lost.

- Add recovery without a new simulation frame through `FortressDriver.recover()` and `FortressSession.begin_recovery()`. Finalize corrected replay and spectator tails while preserving staged input.

- Add E to end the local spectator example's host. Outstanding inputs settle before the viewer drains its complete final history, including after pause and resume.

- Add one-frame backward navigation to the replay viewer, including inspection before a checksum failure. Longer restores remain bounded and can be canceled.

- Add a bounded spectator host publisher that retains refused rows and sends keepalives while delivery waits.

- Add replay playback speeds from ¼× to 4×. Frame stepping and navigation still use exact recorded frames.

- Add expected and actual checksum values to replay failures, including navigation errors. The replay viewer shows both values at the failed frame.

- Add spectator host keepalives for input stalls and paused viewers. Hosts must agree receiver support before sending the new packet kind.

- Add bounded replay checkpoints for faster repeated navigation. The replay viewer restores previously validated boundaries and checks the remaining inputs.

- Add versioned spectator byte delivery with lifetime checks, bounded reordered rows, clean endings and injected-clock host expiry. Games supply authenticated transport.

- Add confirmed-input spectator playback and a playable delayed-view example. Pause and catch up the viewer while the host continues. Live spectator networking remains planned.

- Compare sequential replay playback with actual pinned upstream sessions and independent canonical state histories on both engine pins.

- Add a diagnostic file viewer for online captures. Open JSON locally, inspect retained boundaries and metadata, then play or step through canonical comparisons. Playback identifies the first differing saved state.

- Add a replay viewer for online recordings. Open a downloaded file without a server, then play, pause, step, restart or go to a chosen frame. Playback validates recorded checksums and stops at the first mismatch.

- Add offline canonical diagnostic playback and an online trace reproduction command. Restore a captured window, apply its recorded inputs, and locate the first differing saved state.

- Add optional replay recording to the online example. Select Record replay before Ready, then Download replay to save the first ten minutes of confirmed inputs. Diagnostic capture remains a separate choice.

- Add an `input_delay_recommendation` peer event that suggests a higher input delay from measured round-trip time. Your game chooses whether to apply it. Press R in the online example to apply a suggestion.

- Add `set_input_delay` so a player can raise input delay mid-match. Replays record the change. Press = in the online example to try it.

- Add match recording and playback. Set `replay_max_frames` to record confirmed inputs with engine, addon, seed and session details, then play the bytes with `FortressReplayPlayer`. Playback checks recorded state checksums and stops at the first frame that differs.

- Add peer completion notifications after game callbacks and network controls. Reentrant peer mutations remain blocked until handlers return.

- Add an online checkbox to include bounded game state and inputs in diagnostic downloads. Choose before Ready; capture stays off by default.

- Add opt-in canonical desync traces with bounded state/input history and application metadata. Traces freeze at the first detected mismatch and survive event drains; game payloads remain private by default.

- Add a typed driver completion signal for presentation updates after rollback, stalls and callback failures. Recursive driver calls stay blocked until signal handlers return.

- Add owned rollback, replay-work and stall statistics. The online Diagnostics button excludes room IDs and tokens; game payloads require explicit opt-in. Terminal causes survive event drains.

- Add a playable shots example with adjustable remote-input delay. Move and fire to see prediction, rollback and stalls; confirmed effect pulses play once. Run `examples/integration/integration.tscn` without a server or native extension.

- Add an integration guide and example for your own game: inputs, complete snapshots, the frame loop, stalls and errors. Its effects ledger plays sounds only for confirmed frames, so a shot predicted from late input never plays by mistake.

- Add a playable two-player online example with SignalFish rooms, WebRTC and relay fallback. Install the optional SDK, create or join a room, then ready up and start. Leave and create a fresh room to restart.

- Add per-peer SignalFish relay fallback and direct restoration in one rollback session. Configure the fallback coordinator with both adapters; confirmed history survives overlapping delivery.

- Add bounded SignalFish WebRTC byte delivery with unordered input transport, owned retry queues and sender checks. Reserve mesh packet reads for the adapter and restart after plan replacement.

- Add bounded SignalFish binary relay with recipient envelopes, owned retry queues and send backpressure. Applications retain refused batches and restart after receive overflow or reconnect.

- Add optional SignalFish membership setup with stable UUID slots, handshake agreement, sender checks and v3 plan selection. Reconnect recovery remains planned.

- Add peer RTT, pacing hints, interruption and resume events, and confirmed game checksums. Fixed-membership sessions halt on timeout, closure or desync; create a new session to restart.

- Add fixed-membership byte sessions for 2–8 player slots with retained input retries, cumulative ACKs and mesh confirmation. Applications supply delivery and drain bounded outputs.

- Add a playable two-peer packet-loss example with prediction stalls and recovery.

- Add bounded peer handshakes with explicit configuration mismatch events, injected time and tokens, retries, and synchronization progress.

- Add a playable offline sync-test example with complete integer snapshots and rollback-safe presentation.

- Add complete snapshot-read checks so callbacks can reject trailing bytes before restoring game state.

- Add bounded versioned protocol messages for handshake, inputs, acknowledgements, timing and checksums.

- Add local sync-test sessions, bounded snapshot history, ordered rollback requests, and a synchronous game driver.

- Add a bounded raw input queue with owned bytes, frame delay, and repeat-last prediction.

### Fixed

- Bind oracle launch receipts to the repository identity and source digests captured before execution. A run whose files or commits change mid-execution is rejected instead of publishing ending-state identity.

- Fix paused spectator feedback to name missing confirmed frames while retaining the paused state.

- Fix spectator delay and catch-up shortcuts on layouts with shifted punctuation. Use Y/U and I/O without modifiers.

- Fix spectator host-step failure feedback to retain the failed host callback and frame. Host termination also stops buffered viewing with its original cause.

- Fix peer-example fault shortcuts changing packet policy during active game operations.

- Fix number-row shortcuts in the effects, spectator and peer examples on AZERTY layouts, without requiring Shift.

- Fix refused effects-example restarts clearing confirmed-effect pulses while a game callback or request still owns the match.

- Fix replay controls and failure details pushing the game outside short windows. Scroll controls in smaller windows; wheel scrolling over the timeline preserves playback and failure evidence. (#310)

- Keep online arrow movement available after clicking input-delay and diagnostic/replay export buttons, preserving keyboard button access.

- Fix diagnostic JSON exports containing control characters while preserving Unicode metadata and recorded values.

- Fix conflicting expert-staged input stopping online matches. Rejected keyboard samples preserve clocks and service state so the original input can be retried.

- Fix modified keyboard shortcuts changing or restarting playable matches. Offline restart also ignores held-key repeats.

- Fix imported diagnostic seed text adding misleading status lines. Recorded metadata now appears quoted with control characters escaped.

- Fix restarting the reusable integration loop to replace the game, session, driver, retained input and effect ledger together. Rejected replacements preserve the running match.

- Fix replay controls appearing available while game callbacks or manual replay requests hold playback. Controls become available after completion.

- Fix confirmed effect hooks replacing or advancing the integration example’s active match. Cancellation reports its first cause after the confirmed effect batch.

- Fix local peer matches reporting success after a session stops. Both owned peers now retire, and the match must be reset.

- Fix rejected local peer controls stopping the match. Conflicting expert-staged inputs and invalid controls now allow corrected retries.

- Fix offline, integration and spectator scenes staying paused after temporary ownership holds. Integration playback also repairs missing remote inputs after predicted expert advancement.

- Fix departed example scenes leaving retained matches and replay players usable. Teardown expires pending views and preserves earlier failure causes.

- Fix invalid integration and spectator button values silently wrapping or stopping gameplay. Rejected values preserve the match and controller time.

- Fix spectator pause controls changing playback while a callback or manual request owns the viewer.

- Fix local peer-example reset leaving replaced sessions playable through retained handles. Busy game operations and invalid replacement settings preserve the current match.

- Fix browser replay file-read completion replacing a recording during timeline dragging or changing feedback while game work owns playback.

- Fix spectator status checks leaving buffered playback active after SDK room, identity or receive-limit changes.

- Fix native replay and diagnostic imports exceeding their checked allocation size if a file grows during import.

- Fix ambiguous spectator catch-up key labels by naming Comma and Period.

- Fix SDK callbacks reviving canceled or expired online matches. Unsafe plan or peer-directive reentry stops the old mesh before SDK consumption and requires a fresh session.

- Fix delay prompts and shortcuts outside active online or local peer gameplay. Retain match observations and recovery instructions after failure or leaving.

- Fix driver callback replacement during unfinished expert batches so the original game state stays attached.

- Fix stale spectator host deadline checks after replacing the exposed viewer.

- Fix spectator relay status attributing a replacement viewer's host activity to an earlier SDK getter call.

- Fix recording-limit warnings to include pending frames and prompt finishing before the recording fills.

- Fix diagnostic viewer controls replacing or advancing playback during game callbacks. Successful restart or import retires the previous player.

- Fix leaving an online room during SDK or game callbacks. Leave stops further gameplay and setup, and releases active SDK owners after callbacks return.

- Fix online service and replay-finish controls during callbacks or manual requests. Busy calls preserve clocks, transport, held input and the active match.

- Fix rejected driver input lists and unsupported recovery advancing the accepted session clock. Corrected calls can retry at the last accepted time.

- Fix replay viewer controls changing playback during callbacks or manual requests. Restarting or importing another replay retires the previous player.

- Fix spectator freeze validation to reject unsupported player-slot controls consistently with freeze operations.

- Fix integration controls changing input or clocks before rejecting nested calls, sample conflicts or invalid time. Keep live matches paused during replay and allow corrected sample retries.

- Fix spectator feedback showing active watching while waiting for new confirmed inputs mid-match.

- Fix spectator publication rejecting valid service times after a poll was deferred by an active host request.

- Fix replay prefix arithmetic and checksum reads trusting invalid recording dimensions. Malformed recordings remain unavailable for export.

- Fix input reads with missing or unknown status metadata. Malformed constructed views now return `INVALID_CONFIGURATION` and preserve caller buffers.

- Fix replay failure diagnostics for missing or incomplete input digests. Playback and paused inspection identify absent evidence and preserve the computed row digest.

- Fix direct socket errors being hidden by successful relay polling. Terminal SDK failures now stop the fallback coordinator; ordinary busy sends still recover through relay.

- Fix contradictory repeated peer-drop certificates being ignored. A changed frame or value digest stops the pending agreement without freezing player history.

- Fix lost peer-drop acknowledgements stopping commit recovery at the negotiation deadline. Committed survivors retry until every live survivor acknowledges.

- Fix SignalFish spectator startup rejecting real SDK protocol metadata. Host and viewer bridges read the SDK's typed version and size limits.

- Fix remote peer-drop donors stalling healthy history recovery when another survivor refuses a certificate packet.

- Fix clean spectator completion at the frame and request-token limits. Fully played host tails report completion without requesting another frame.

- Fix spectator host sends during an expert request opened by an SDK getter. Publication retains the original packet until the request finishes.

- Fix custom spectator byte transports rejecting authenticated rows after playback history expires. Obsolete rows preserve playback and cannot renew host liveness.

- Fix SignalFish transport cleanup requested from callbacks. Direct, relay and fallback queues and relay observers are released when the active poll returns.

- Fix spectator relay failures from delayed authenticated rows after playback history wraps. Obsolete rows leave playback and host expiry unchanged.

- Fix replay accessors exposing incomplete rows or indexing missing metadata. Invalid row reads return no inputs or digest while complete earlier rows stay readable.

- Fix clean spectator closure discarding accepted rows beyond a gap. Fill the missing rows and retry `finish_host()` after `PREDICTION_STALL` to play the full tail.

- Fix replay prefixes padding missing input and checksum storage. Trimming preserves incomplete data and refuses invalid exports instead of inventing recorded bytes.

- Fix spectator relay cancellation being reported as successful completion at the final playback boundary, including empty matches.

- Fix replay checkpoint eviction during backward inspection. Revisiting an older uncached boundary preserves the initial state and newest checkpoints, including a verified match ending.

- Fix spectator stop reporting after external or callback cancellation. Preserve the original cause through later host errors; `is_complete()` and the example distinguish clean playback completion from cancellation.

- Fix replay prefixes inventing missing input digest bytes. Incomplete retained rows remain unavailable for portable export and stop playback at their owning frame.

- Fix peer-drop history transfer waiting on an unrelated survivor's refused plan. Healthy survivors receive their missing original inputs while the blocked link retries.

- Fix trimmed captured replays losing an available checksum for their new final state. Prefixes without that evidence retain their existing validation limits.

- Fix spectator example messages for startup buffering, paused final tails and lost history. Paused tails explain how to resume or step; lost history explains how to restart.

- Fix spectator example service calls during active callbacks or request batches consuming time or stopping viewing. Busy controls preserve the current match.

- Fix completed spectator playback reporting a relay failure during continued polling or late packet delivery. Cancellation and playback failures remain explicit.

- Fix local multiplayer and spectator restarts leaving retained old sessions playable. Restarts refuse active callbacks or request batches.

- Fix replay configuration raising script errors for unrelated configuration objects. Invalid replacements now preserve playback.

- Fix replay completion reporting while checkpoint navigation or state revalidation is still in progress.

- Fix spectator playback continuing after SDK receive limits become too small for the agreed packets.

- Fix coordinated-drop control retries flooding healthy survivors or postponing their deadlines when another link refuses publication.

- Fix replay export accepting malformed recording storage or missing input digests. Invalid recordings now return empty bytes instead of producing broken files.

- Fix retained-history publication starving healthy survivors when several other links refuse donor chunks during coordinated peer drop.

- Fix replay navigation accepting changed state at retained checkpoints. Repeated playback now checks canonical bytes even without recorded state checksums.

- Fix spectator startup acceptance after viewer termination or during active game requests. Retry acceptance after the viewer becomes idle.

- Fix malformed replay objects replacing active playback or reaching unchecked storage reads.

- Fix spectators continuing buffered playback after their selected host leaves or reconnects. Stop publication when the admitted viewer disconnects; unrelated roster changes preserve ongoing streams.

- Fix peer completion and transport calls bypassing shared callback guards. Handler cancellation now returns the first terminal cause.

- Fix the last surviving peer discarding already received departed-player inputs. Preserve original inputs and statuses through the final receipt before freezing every departed slot.

- Fix spectator completion handlers consuming cancellation events before later handlers and callers can observe them.

- Fix spectator host publication after SDK lifetime signals during setup or identity reads. Rejected publication leaves player gameplay running.

- Fix peer advancement and recovery hiding exhausted counters behind input errors or publishing input before termination.

- Fix spectator SDK getters detaching or replacing playback during validation. Old callbacks cannot alter a replacement viewer.

- Fix completion handlers advancing or reconfiguring a shared session through another driver or the expert API. Handlers now observe the same completed frame; cancellation remains available.

- Fix late spectator retries interrupting a clean buffered final tail. Identical retained rows and control packets remain idempotent until playback ends.

- Fix repeated spectator keepalives starving queued confirmed rows when receive work is limited to one packet per poll.

- Fix pressured peer-drop history plans immediately repeating to survivors that already accepted them, preserving output capacity for missing input rows.

- Fix reordered spectator rows blocking recovery behind a full playback ring. Bounded polling retains refused packets while accepting earlier missing rows.

- Fix refused peer-drop controls waiting another retry interval after output pressure clears. Repolling can publish the original phase immediately.

- Fix graceful-drop followers certifying a supplied frozen value that conflicts with their retained actual input. Conflicting history now ends agreement before the slot freezes.

- Fix full ten-minute online replays being refused by the viewer's file-size limit.

- Fix malformed spectator startup versions creating an unusable agreement. Corrected valid answers remain accepted after malformed input.

- Fix spectator restart leaving old drivers able to play buffered inputs. Successful stream replacement now terminates its prior owned viewer.

- Fix peer drops rewriting exposed confirmed history. Survivors certify retained actual history before agreeing a raised cut. Missing history ends the match safely. The handshake requires the new drop feature; update every peer together.

- Fix disconnected player statuses in replay recordings. New version 5 files cover input bytes and statuses with each row digest; version 4 files still load with all-confirmed defaults.

- Fix replay exports exposing unconfirmed or unrepaired tails. Coordinated drops repair staged rows, including predicted disconnect semantics.

- Fix expired peer-drop barriers accepting buffered commits. A pending barrier expires at its exact deadline; an already committed drop remains acknowledged.

- Fix unfinished peer-drop barriers silently omitting a lost survivor. The match now ends with `participant_lost`; an already committed drop remains valid.

- Fix peer-drop commit retries after a lost acknowledgement. Survivors acknowledge matching duplicate commits without repeating the drop. Refuse control messages from another operation, era or coordinator.

- Fix spectator startup offers bypassing host expiry and active callback guards. Retries cannot revive an ended viewer or answer for a replaced viewer.
- Fix spectator player-freeze calls replacing confirmed host inputs. Both freeze methods now return `UNSUPPORTED` for spectators.
- Fix replay Pause, Step and seek destinations accepting corrupted input rows until playback resumed.

- Keep the match running when a mid-match input delay raise cannot be sent. A peer session that could not hand the added frames to a peer ended the match with `PROTOCOL_FAILED`. The raise is now checked before the delay changes, so a peer that cannot take the frames or a catch-up row that was already released is reported as `NETWORK_BACKPRESSURE` and the match keeps running with the old delay.

- Fail a test case that dies before its last assertion. A GDScript runtime error inside a case aborts that function, the caller resumes and still marks the case complete, so the runner reported a broken case as passed with a truncated assertion count. The launcher now merges the engine's output into one stream, attributes the abort to the case that was executing, fails that case with the suite, the aborting line and the engine message, and keeps every other case's record.

- Fix the exported online witness failing its corrupt control at random. The corruption is applied while a peer restores a snapshot, and the control held one input for the whole round, so the repeat-the-last-actual prediction was always correct and no peer ever rolled back. The witness now holds the changed input until every peer has restored, so the deliberate corruption always lands, and the corrupted peer must terminate with the desync reason while the healthy peer keeps its confirmed history.

- Fix the canonical diagnostic trace losing the divergence region after a rollback. The window follows the simulation back to the restored frame, so the frames that follow a rollback are recorded instead of rejected, and the restored boundary keeps its canonical state so the re-opened window stays restorable.

- Fix spectator playback simulating a stale host row. A missing retained row now ends the advance with `HISTORY_UNAVAILABLE` and no game callback.

- Fix one source of truth for the roster and sample-width limits. The configuration and the spectator byte envelope share the same bounds.

- Fix the spectator guide claiming 72 model schedules. The model runs 120.

- Fix the integration guide promising a sound per shot and advising a bare reconfiguration. The example calls a game hook, and a restart needs a new game object.

- Fix the oracle launchers so the documented `make` commands find a Godot engine installed on `PATH`. The engine is resolved before the Rust toolchain is installed, and the receipt names the executable that ran.

- Apply one engine-resolution rule to every probe and launcher. A name on `PATH`, a relative path and an absolute path now resolve the same way, and a name that names nothing fails with a readable message.

- Keep the browser error inventory when the ownership watchdog rejects a run, and record each ownership round as it starts, so a timeout names the round that was running.


- Fix driver input submission hiding terminal frame or batch exhaustion. Exhausted calls terminate before retaining new samples.

- Fix replay Step and Pause accepting an unchecked displayed boundary. Both actions now report checksum failures immediately and preserve the failed input for inspection.

- Fix spectator stream packets and timeouts affecting a viewer after direct session reconfiguration. Reconfigure the stream with a fresh connection identity to resume delivery.

- Fix incompatible reflected snapshot and input callback types being accepted during setup. Rejected replacements preserve the active game; erased engine metadata cannot identify every mismatch.

- Fix incompatible built-in game callback parameter types being accepted during setup. Invalid replacements leave the active game intact.

- Fix replay navigation bypassing bounded snapshot validation at paused frames. Callback and snapshot failures now stop playback with the selected frame.

- Fix corrected driver retries after incomplete multiplayer input lists. Missing local samples are rejected before retaining other players’ buttons.

- Fix spectator confirmation being restricted by player-only mesh controls. Played host-confirmed rows remain available for export.

- Fix invalid game callback argument counts being accepted during driver, replay and diagnostic setup. Configuration now fails early and preserves any previous playback.

- Fix corrected driver retries after malformed multi-player input lists. Invalid sample metadata is rejected before any earlier sample is retained.

- Stop matches explicitly when game callbacks return invalid values. Drivers release request views and notify peer closure instead of leaving the match stalled.

- Fix stale WebRTC callbacks after connection closure. Create a fresh connection wrapper before initializing a replacement.

- Fix replay validation accepting failed snapshot writes when the callback returned a matching checksum. Playback now stops with `SNAPSHOT_FAILED` at the affected frame.

- Fix a match stalling after a long input backlog when peers used different handshake `max_packet_bytes` values. Peers now share their limits while connecting, and each sends batches that fit the smaller one.

- Fix a match stalling when one peer used a larger `max_input_frames` than another. Each peer now accepts batches up to the protocol limit of 128 frames, and the option only limits what it sends.

- Fix a match ending with `PROTOCOL_FAILED` when peers used different `queue_capacity` values and one raised input delay. Peers now compare capacities while connecting and refuse to start. **Behavior change:** the wire layout is now version 2, so older builds cannot join. Set `queue_capacity` on the handshake profile when you change it from 128.

- Fix peer sessions ending with `PROTOCOL_FAILED` when a large `input_delay` overflowed the other peer's input queue. **Behavior change:** `configure` now returns `INVALID_ARGUMENT` for a starting delay above `FortressPeerSession.max_input_delay(config)`.

- Fix SignalFish plan callbacks reviving ended adapters or recursively detaching meshes. Replacement attachment waits until teardown returns.

- Fix Firefox WebRTC connections failing when SignalFish omits ICE media IDs. The connection factory resolves missing IDs from the remote SDP while preserving explicit IDs.

- Fix stale packets and SDK callbacks ending restarted online games. Foreign packet identities cannot change gameplay or liveness, and callbacks from an old connection cannot change a later room.

- Fix online failures leaving signaling connections open. Failed games close their connections and keep movement stopped; use Leave / new room to join a fresh match.

- Fix peer timeouts delayed by another peer's full outgoing queue. Recoverable send pressure no longer prevents polling other links.

- Fix online expiry checks while outgoing batches are refused. On resume, overdue matches stop before buffered traffic or movement; leave and create a fresh room. Handshake timeouts remain observable under retry pressure.

- Fix online sessions ending when gameplay packets overtake the final handshake reply. Valid early packets are discarded until synchronization completes, and the sender retries its original inputs.

- Fix SignalFish teardown errors after Godot removes a failed WebRTC peer. Install `FortressSignalFishWebRTCMultiplayerPeer.create` as the mesh's `multiplayer_peer_factory` before its first plan.

- Fix stalled meshes after pending inputs drain by repeating bounded receipt gossip. Keep stalled samples unchanged and confirmation bound to actual inputs.

- Fix invalid transport token callbacks retaining oversized data. Relay and WebRTC adapters validate null or exactly 16 bytes before copying.

### Improved

- Improve local-input preflight by avoiding copied retained samples during driver and peer validation. Public sample reads keep their ownership guarantees.

- Improve driver step and recovery allocation by reusing the completed request batch's status snapshot.

- Improve multi-peer input processing by reading receipt frames without copying retained packet history. Public status snapshots keep their ownership guarantees.

- Improve wide-input queue insertion with native byte copying while preserving input, prediction and rollback-floor ownership.

- Improve driver handling of repeated identical local samples. Each player submits once after the complete list passes validation.

### Changed

- **Breaking**: Change the replay file format to version 4. Every frame now carries the digest of its own input row, so a corrupted input is refused with `DESYNC` at the frame that owns it - including a row in front of a frame that carries no state checksum. Version 1, version 2 and version 3 files are refused with `UNSUPPORTED_VERSION`. A recording now spends 16 more bytes per frame, so the largest recording a configuration can hold is smaller.

- Name the reason the replay viewer refuses a file. An older format version, a malformed file and an oversized file each get their own message.

- Build the pinned relay server into one revision-keyed shared cargo tree instead of a per-run output directory. The executable is still published at `<output>/target/debug/signal-fish-server`, so every documented path and the build receipt keep working.

- Reuse the pinned relay server's compiled dependencies across builds and across the six SignalFish CI jobs. The build now keeps its crates at one fixed Cargo home, the CI caches the dependency tree, and the server itself is still rebuilt from the pinned source every time.

- Prune stale scratch and superseded container caches on every container start, and report the repository cache without modifying it.

- **Breaking**: Change exact endpoint byte budgets to reserve one extra local input frame for acknowledged-input recovery.

- Stage the Python helpers a native test run executes into a private digest-verified image. Receipt `helper_sources` names each loaded module's own staged file, so it binds the bytes Python actually imported, including across repeat `main()` calls; the live tree stays an evidence input whose drift during the run still fails qualification as `helper_source_changed`, and the staged image itself fails as `helper_image_changed`.
