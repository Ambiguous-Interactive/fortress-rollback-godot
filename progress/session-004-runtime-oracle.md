# Session 004 — Actual upstream runtime traces

Goal: advance PLAN.md through a green, reviewed, squash-merged session PR.
Base: `50b6fbd13718e9968931897ac4c9fc43468faa70`.
Branch: `session-004-runtime-oracle`.
The session PR and linked issue updates own final current-head CI, feedback scan,
merge SHA and merge-triggered main CI evidence.

## Starting audit

Clean local main matched origin/main. No open PR or dependency PR remained.
All main workflows passed: harness 38082512398, devcontainer 38082512431,
reference 38082512420. GitHub CLI has no active credential; the connector
provides authenticated reads/writes and SSH Git provides fetch/push.
The active roadmap blocks core implementation on actual runtime oracle evidence.

## V2 runtime evidence

Development-only Rust code calls pinned upstream public sync-test APIs.
It fulfills actual save/load/advance requests in returned order, saves owned
game clones, and records statuses/errors and event drains. It does not rewrite
the upstream rollback algorithm. The committed lockfile and Rust 1.94.0 pin
disable optional/default upstream features. Source archives are digest-verified
and re-extracted before execution.

Version-one scenarios/traces carry exact configuration and immutable source
revision. The integer reference game has canonical frame/player bytes and a
lossless unsigned128 diagnostic checksum. GDScript independently executes game
requests, saves owned bytes, and restores only its own snapshots. Python checks
each input and canonical state prefix from the original submitted histories.

This is game-boundary conformance, not Rust/Godot session parity. Public sync-test
does not expose confirmation and emits no events at this pin; confirmation is
null rather than invented. V2 remains open. Follow-up
[#59](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/59)
defines P2P setup, injected time/delivery, observations and actual Godot-session
execution. V3 and production core gates remain open.

Contract and commands: [oracle](../docs/oracle.md).

## Red-green and review

Initial schema/process tests failed before the implementation existed.
Fresh adversarial review reproduced a temporal permutation that retained the
final sum, an embedded float scenario accepted by Python equality, and an empty
standalone Godot replay reporting success. New controls failed before repair.
The prefix oracle, independent embedded-schema validation and standalone strict
schema now reject those cases. This is new capability, with no older working
oracle revision for a pre-regression comparison.

A second fresh-context reviewer audited every applicable attack surface and
reported no findings. Formatting, source widths and code review passed.
The adapters fail on process errors, malformed streams and inconsistent saves;
unknown fields are also checked against the actual Rust/Godot binaries.

A source-only post-error concern did not reproduce: missing inputs at frame four
with distance two recovered after complete submission. Removed the unverified
claim and added late missing-input/retry cases to the permanent runtime corpus.

## Verification

| Gate | Observed local result |
| --- | --- |
| Offline oracle schema/process suite | Nine tests passed with data-driven mutations |
| Harness tooling | 90 tests passed |
| Offline reference suite | 27 methods; 25 passed, two native controls skipped in offline mode |
| Harness/source checks | Generated index/stubs fresh; source width 180 passed |
| GDScript format/lint | All oracle files passed |
| Minimum/current runtime matrix | 21 scenarios per engine, every player count 2–8 |
| Per repetition | 3045 operations, 2352 requests: 903 saves, 203 loads, 1246 advances |
| Bounds and recovery | Distance/delay 0/0, 2/2, 7/7; 20 successful frames; early/late missing input and retries |
| Fresh-process equality | Each Rust trace and each Godot replay ran twice and matched exactly |
| Actual process mutations | 13 checked rejections per engine |
| Engines/platform | 4.3.77dcf97d8 and 4.7.2.ed1daf0bf; Linux arm64 |

Receipts: `.cache/reference/results/oracle-4.3-final/receipt.json` and
`.cache/reference/results/oracle-4.7.2-final/receipt.json`.
CI executes the same native oracle matrix on x86_64 with both pinned engines,
alongside existing reference, browser, harness and devcontainer gates.
No browser oracle, production addon or full parity claim is made.

## Retrospective and guidance audit

Corrected bootstrap rollback/event/transport claims against pinned enums and
the reviewed ADR. Retired invented event names, fixed channel/wire promises,
an unreleased replay layout and degraded-mode advice. Testing guidance now
requires embedded artifact validation and intermediate submitted-history checks.
Generated discovery files are regenerated from the canonical skills.

Artifact: [runtime oracle retrospective](../.llm/retrospectives/2026-10-10-runtime-oracle.md).
Retro: findings-acted
