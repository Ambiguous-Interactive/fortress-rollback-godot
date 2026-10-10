# Verification and release evidence

Status: development contract for [B4](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/15).
This policy defines gates; it does not claim that their future runners exist.
The [implementation plan](../PLAN.md) owns supported product decisions and
GitHub task issues own changing implementation status.

## Evidence before closure

Each behavior task records the following in its issue and implementation PR:

| Field | Required evidence |
| --- | --- |
| Contract | Observable behavior/invariant, upstream revision and source/test identity, or reviewed divergence |
| Hypothesis | A falsifiable prediction identifying what the change should repair or establish |
| Red | Actual failing reproduction or negative control, command, seed, input and exit status |
| Change | Smallest complete repair of the failure class, including a sweep for related defects |
| Green | Exact commands, versions, features and actual results of applicable gates |
| Independence | Expected canonical state bytes from input history or independent invariants, alongside upstream comparison |
| Limits | Unsupported configurations, omitted gates, unexplained differences and linked follow-up issues |
| Review | Author review, fresh adversarial review when required, resolutions and retrospective |

A bug fix must fail before the repair and pass afterward. Run the same regression
on a pre-regression revision when one exists. If the defect predates the available
history, say so; do not invent a passing base. Tests are justified by a credible
failure, rather than mirroring implementation internals.

Upstream test success demonstrates the pinned reference, not the Godot port.
Issue creation, successful startup, connection events and flat memory charts
cannot substitute for implemented behavior, canonical state equality or measured
allocation evidence.

## Evidence layout and reproduction

Checked-in development contracts, pins and compact baseline summaries belong
under `docs/`. Reproducible entry points belong under `scripts/`. Large upstream
trees, downloaded tools, browser exports and raw result logs belong in ignored
development caches; CI uploads relevant logs as artifacts. Never package these
materials with the runtime addon. Preserve source revision, source/license
notices and transformation history for translated fixtures or models.

Every result bundle records:

- Repository commit, pin-manifest digest and revisions of all external inputs.
- Engine/editor/template pair, Rust features/lockfile/toolchain, browser runner
  and browser build, model checker and model revision as applicable.
- Exact invocation and working directory, OS/architecture and relevant hardware.
- Explicit scenario seed, scenario-format version, configuration and operation
  sequence; protocol time/delivery decisions where networking is involved.
- Exit status, completion marker and count of executed tests/consumed records.
- First differing frame/record/byte, expected and actual values, and minimized
  scenario retaining validity and the original failure class for any divergence.

Use lossless strings or byte encodings for wide integers in JSON; never let a
browser number conversion truncate checksums. Redact credentials before uploading
logs. Reproduction must use committed pins and verified cache artifacts, not a
developer's undocumented global installations. A cache miss in offline mode,
digest mismatch, missing feature or tool error fails explicitly.

## Test tiers

| Tier | Required scope |
| --- | --- |
| PR | Harness/tooling gates; changed-path unit and core tests; exact fixed differential corpus; independent invariants; short seeded network faults for 2–8 players; minimum Godot 4.3 and pinned current stable |
| Nightly | Larger seeded exploration, valid shrinking, comparator/runner/model mutations, bounded models and real exported-browser transport integration |
| Release | PR/nightly evidence plus Linux/macOS/Windows state-byte equality; Chromium/Firefox/WebKit and mixed peers; direct/relay/fallback; sustained bounded-memory runs; clean addon install without development tools |

Until a tier exists and has completed successfully, its gate is **missing**, not
green. Select the scope appropriate to the implementation task; an early baseline
task need not pretend to exercise nonexistent rollback code. Release acceptance
requires every advertised supported feature's gates, even if a path-filtered CI
workflow did not run. Report actual Safari/device evidence separately from WebKit
automation. Performance budgets come from repeated measurements of noise and
reference hardware, not arbitrary portable-CI time thresholds.

## Seeds and repeatability

Use explicit fixed seeds in the PR corpus. Exploring jobs record each seed and
its generator/version before execution. Keep minimized failures permanently with
provenance. Run twice with all fixture state reset and compare ordered semantic
records and canonical state bytes; fresh-process repetition catches leaked state.
Do not compare timing, temporary paths, random protocol token spellings or test
completion order as semantics. A projection may normalize these representations
only while preserving identity relationships, duplicate/ACK relationships and
event/request order. Document the projection; do not normalize actual disagreement.

Missing tests, zero matching cases, unknown records, truncated traces, partial
consumption, parse/load errors, uncaught script errors, crashes and watchdog
expiration all fail. An upstream failure is recorded and investigated, never
hidden through golden regeneration or by dropping its case from the inventory.

## Independent and formal claims

When upstream disagrees with an independent invariant, minimize and investigate
before choosing either result. Intentional divergence records the upstream
revision/test, conflicting invariant, reproducible evidence, chosen behavior,
compatibility impact and review decision. It remains visible in the parity ledger.
Golden updates require the same review as a behavior change.

A bounded model establishes only its stated domain and assumptions. Record bounds,
fairness/recovery assumptions, runtime-to-model mapping, unmapped transitions,
full trace consumption and non-vacuity witnesses. Mutation controls must prove
that invalid transitions are rejected for the intended reason. Timeout, tool
failure and parse failure are not successful invalid-transition rejection.
Rust-specific Kani/SMT/Loom results do not establish GDScript correctness.

## Release checklist

- Every supported API/behavior has a mapped passing port test or reviewed
  applicability decision; experimental features are labeled and excluded from
  supported claims explicitly.
- Applicable differential, independent, property, fault, model and platform
  gates ran at the release commit with no unexplained divergence.
- Runner/comparator/model negative controls fail on their intended defects;
  each evidence stream is complete and non-vacuous.
- Engine/export/browser versions, network profiles, bounded storage limits,
  performance environment and known exclusions are published.
- Addon packaging contains only runtime files and required attribution;
  clean native/web installation works without Rust, model tools or reference
  caches. Constructing a candidate does not authorize publishing a release.
- Reviewer feedback and CI failures are resolved, task/parent status reflects
  actual evidence, and the session log and retrospective are committed.

## Current worked example

The [reference baseline](reference/README.md) is the first reproduction bundle.
Its pin manifest and run reports must be audited against B1's requirements before
closure. It proves only the listed upstream tests and engine controls. Pending
browser execution, formal checks, addon packaging and port differential coverage
remain missing until their named gates exist and run. The session progress log
records the concrete red/green CLI-probe repair and its history limitation.
