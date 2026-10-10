# Session 002 — Reference foundations and reliable verification

Goal: advance PLAN.md to one green PR, carry relevant in-progress work,
restore main CI, and establish the next correctness-first implementation gates.
PR: https://github.com/Ambiguous-Interactive/fortress-rollback-godot/pull/54.

## Decisions

| Decision | Choice |
| --- | --- |
| Existing work | Retain all nine relevant devcontainer/OpenCode changes; correct unverified claims and acceptance gaps |
| Reference revisions | Preserve all three research SHAs; record verified source/tool integrity separately from port coverage |
| Cache | Ignored `.cache/reference/`, verified before use; runtime Rust is not added |
| Session scope | One PR with small coherent commits; implementation roadmap remains issue-owned |
| Evidence | Completed counts, explicit status, independent negative controls; failed reruns invalidate old success |
| Inventory | Exhaustive file hashes plus conservative source-family discovery; all semantic coverage stays pending |

## Task log

### T0 — Authoritative repository/external audit

Started from main `3888b90` with nine uncommitted relevant tooling files.
No open PR or dependency PR existed. GitHub CLI had no usable token; the
GitHub connector supplied authenticated API actions and Git SSH supplied push.
The repository moved from `wallstop` to `Ambiguous-Interactive`; PLAN issue
links now use the canonical owner. PLAN itself was previously local/ignored;
it is carried into the PR as the durable issue navigation document.

Main harness CI passed. Main devcontainer jobs were cancelled after the runner
received a shutdown signal, not a product test failure. Retried x64, then arm64;
run https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/38075509454
attempt 3 completed successfully on both architectures.

### T1 — Retained tooling and false-green repair

Packaged npm Codex/OpenCode v2, Codex persistent volume/auth example and OpenAI
firewall hosts were retained. Removed unsupported universal standalone-Codex
failure and OpenCode-v1-schema claims. Corrected `--build-no-cache` guidance.

Fresh review found failed version commands could pass acceptance, a shadow
Codex executable could pass merely because a package existed, and a malformed
MCP command could pass because `godot-mcp` appeared after a broken executable.
New controls reproduced three false-green failures before repair. Check process
status, launched executable/package association and exact local server command.
The version-command bug also existed in base `3888b90`, so no passing
pre-regression revision exists for that failure class.

Actual OpenCode runtime discovery was added rather than relying on JSON shape.
Local warm-daemon acceptance passed 28/0, then fresh PR images failed 25/3.
Isolated fresh daemon reproduction: `debug config` succeeded, first list returned
no servers, next list showed all three pending. Catalog initialization is async.
A deterministic regression fails against commit `4dd09ca`, passes after bounded
polling; seven focused helper methods and a real fresh-daemon control pass.
Raw config/server output is kept private; optional remote auth need not succeed.
Automatic PR feedback found human warning glyphs hid authentication statuses.
A red control confirmed it. Discovery now queries the structured runtime API;
authentication, disabled and future statuses retain their server identities.
Malformed/missing catalogs still fail. Fresh review and isolated real CLI passed.

### T2 — Pinned reference baseline (B1)

All three pinned source archives verified. Pin Godot4.3/current4.7.2 editors and
matching templates for both Linux architectures; Rust1.94.0/rustup1.29.1, features,
Cargo.lock, Playwright1.56.1 registry/package integrity and Chromium artifacts;
TLC1.8.0 artifact and nonexecuted Firefox/WebKit registry revisions.

Actual offline reruns after repairs:

| Gate | Result |
| --- | --- |
| Upstream queue | 115 tests passed twice |
| Upstream sync-test | 8 tests passed twice |
| Upstream mesh smoke | 3 tests passed twice; 2/3/4 peers, fixed seeds1,2,3,5,8,13,21,34 |
| Same-schedule trace | 1 test passed twice; upstream compares traces internally |
| Planted state divergence | 1 oracle/in-band detection test passed twice |
| Godot4.3 and4.7.2 native | Byte-codec marker twice and actual invalid-script rejection for each |
| Actual web exports | Both editors/templates executed marker78563412 in Chromium141.0.7390.37; no browser errors |

The initial parser omitted an expected-panic sync test; completed-count validation
exposed7 parsed versus8 executed. Fixed parser and added regression. Fresh review
then reproduced six stale-success/timeout failures. Both runners now invalidate
prior success before setup, clear only owned logs and preserve timeout output.
Sixteen reference/inventory controls pass after repair. Actual offline Rust/web
reruns regenerate `status: passed` reports bound to the current manifest.

See `docs/reference/baseline.md`, checked-in summaries and setup commands.
Reference CI reproduces actual tests and uploads raw logs. B1 remains open for
unverified closure gates; no addon release package or formal model run is claimed.

### T3 — Source inventory (B2)

Pinned scan verifies 632 files, 337 source families and lexical candidates with
source hashes/revisions, Cargo feature maps and provisional task/epic routing.
Nine inventory controls cover add/delete/rename/hidden/inline/feature drift,
symlinks and forged coverage. `--release` intentionally fails: lexical discovery
cannot establish semantic audit or executed port coverage. Imported source
excerpts retain Fortress notices under `docs/reference/licenses`.

Issue #55 records the evidence-backed semantic coverage verifier follow-up:
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/55.
B2 remains open for semantic split/applicability reviews, real port mappings,
canonical-guidance corrections and SignalFish lifecycle audit.

### T4 — Reviewed interfaces and evidence policy (B3/B4)

`docs/contracts.md` specifies typed session/game/driver/transport contracts,
before-frame snapshots, exact defaults, ownership/view expiry, batch completion,
failure/time/lifecycle rules and acceptance walkthroughs. Fresh review found a
per-slot actual-input versus global-confirmation ambiguity; corrected frozen
prediction episode semantics and added asymmetric three-player witness.
Reviewer confirmed the correction matches pinned source and accepted.

`docs/verification-policy.md` defines evidence layout, PR/nightly/release tiers,
seed/repetition rules, divergence review, formal limits and release checklist.
No concrete review finding. These are development contracts, not implemented
runtime classes or proof that the port's future gates have run.

### T5 — Deterministic native runner (V1)

Dependency-free GDScript suite execution uses explicit assertions, canonical state
bytes, signed seed strings and fresh fixture instances. The standard-library
Python entry point validates complete records and repeats in fresh engine
processes. It rejects errors even after a completed case and zero engine exit.
Controls cover byte mismatch (frame 7, byte 1), parse/missing/incomplete suites,
uncaught and after-completion errors, static leakage and watchdog expiry.
Both Godot 4.3 and 4.7.2 execute the controls and repeated self-suite.
Fresh review reproduced invalid UTF-8 version output leaving a prior success
receipt; the receipt is now invalidated before probing and failure output retained.
Browser hosting and actual port simulation suites remain future work.

## Review and final gates

Devcontainer fresh review: findings repaired; recheck accepted with no remaining
code defects. Contract review: prediction clarification accepted. Reference
review: stale reports/timeouts repaired; final recheck accepted.

Runner fresh review independently repeated all six controls and both official
wrappers on the minimum/current editors; no remaining findings.

Local final checks: `make llm-index lint-llm test-llm` (72 tests),
`make test-reference` (22 methods, two engine methods intentionally skipped
without an editor), explicit engine controls (six methods per 4.3/4.7.2),
both official runner executions, and `bash .devcontainer/verify.sh` (28/0).
GDScript format/lint, minimum/current imports and diff checks passed.
The PR checks tab owns final-commit CI evidence; reference CI executes both
engine controls rather than accepting the offline skips.

Existing baseline CI passed all three reference jobs:
https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/38076804279.
Tooling CI passed both architectures and harness CI. Final work is aggregated
in PR #54; no bot review was explicitly requested. Issue #55 owns evidence
certification. Issues #12–16 remain open with artifact links and precise remaining
gates; no epic is closed prematurely. Fresh curation accepted the retrospective.

## Retrospective

Findings acted on in the existing testing skill and devcontainer knowledge topic;
removed stale unsupported claims and recorded
`.llm/retrospectives/2026-10-10-reference-foundations.md`.
Retro: findings-acted
