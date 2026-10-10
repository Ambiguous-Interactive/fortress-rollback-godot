# Session 003 — Representation experiments and session delivery

Goal: advance PLAN.md with measured representation prerequisites, implement
standing session delivery and user-copy guidance, and enforce source width 180.
Base: `97c0d5bfef7eb5f746eae7bb51e6e573ff7e5e04`.
Branch: `session-003-ownership-and-shipping`.
The session PR's checks and timeline own final CI and merge evidence.

## Authoritative audit

Started from a clean main; the prior foundations PR #54 was already merged.
No open PR or dependency PR required incorporation. Main checks all passed:
LLM harness run 38080801524, devcontainer run 38080801517, reference run
38080801489. Existing implementation issues remain the changing backlog.

GitHub CLI had no active authentication. The authenticated connector provides
remote reads and writes; plain SSH Git provides fetch/push. Public REST reached
its rate limit during scanner reruns and returned incomplete evidence, rather
than a clean verdict. A historical PR54 scan covered two inline comments,
two submitted reviews, zero conversation comments, seven successful check runs
and every annotation. The connector independently confirmed its fixed thread
was resolved. Final session scanning must use the current session head.

## Delivery and copy guidance

Canonical `ship-session` specifies green current-head CI followed by complete
feedback scanning on four surfaces, a fresh pre-merge scan, squash merge under
standing authorization, merge verification and local main synchronization.
Context, GOAL.md, PLAN.md and harness maintenance link this procedure. GOAL.md
is now tracked so future checkouts retain the requested session contract.

The `user-copy` skill adapts unity-helpers' comments, PR titles/descriptions,
commit subjects/bodies and CHANGELOG rules to GDScript. Both new skills cite
exact inspected sibling revisions; generated indexes/stubs are regenerated.

A dependency-free read-only feedback scanner pages inline comments, reviews,
conversation comments, all check attempts and every annotation. It validates
counts, schemas and unique identities, checks the expected head, and rereads it.
Its output distinguishes coverage from adjudication and requires MCP/GraphQL
thread-resolution inspection. It never automatically declares feedback addressed.

Fresh review reproduced malformed check schemas, duplicate pagination IDs and
empty expected-head verification bypass. New controls failed first, then passed
with the repairs. All 16 scanner tests pass; the independent recheck is clean.

## Source width

EditorConfig, gdformat and gdlint use 180 characters. A source checker covers
tracked and new source/config files, including extensionless hooks. Verbatim
source-inventory data and dependency receipts remain data artifacts. All authored
source lines fit the limit; hooks, pre-commit and unconditional harness CI
apply the same checker. GDScript formatting preserves the intentional parser
failure fixture. Python, JavaScript and Docker command wrapping preserves data.
Boundary tests cover 180 versus 181 and untracked hooks; fresh review is clean.

## R1 — Integer and encoding contracts (#22)

The pinned Rust 1.94.0 oracle independently generates 116 signed64 arithmetic
rows, 28 unsigned/signed fixed-width byte vectors and eight FNV known answers.
Its checked-in fixture exactly reproduces without dependencies. Unsigned64/128
use unsigned32 limbs/bytes, and wide JSON values remain decimal strings.
Bounded helpers validate widths, offsets, signed32 ranges, limb counts,
division overflow, shifts, frame exhaustion and wrapping unsigned16 sequences.

An endian mutant fails instead of changing the oracle. New FNV vectors fail
against the original sample, whose constants and 63-bit mask were incorrect.
Issue #56 records that defect. Standard signed64 FNV bit patterns now match
independent answers, incremental updates, reset and signed integer encoding.
The diagnostic eight-byte sample remains separate from the negotiated 16-byte
session checksum. Fresh code review independently regenerates Rust vectors,
checks published answers and runs both native engines; no remaining finding.

Evidence: [integer experiment](../docs/experiments/integer-encoding.md).

## R2 — Buffer and snapshot ownership (#23)

Probes measure PackedByteArray, typed arrays, nested RefCounted objects and
StreamPeerBuffer boundaries. Assignment and arguments alias packed arrays;
`duplicate()` owns bytes. Deep collection duplication still aliases objects.
A research representation selects preallocated input/snapshot bytes, staging,
checked operation views, lengths, protected slots and frame/generation tags.

A protected A survives four ring wraps; stale tags, overflow, partial loads and
expired views fail. Caller mutation and callback-copy mutation cannot edit
history. Fresh review caught nested mutation outside A's payload; the repaired
probe now serializes, mutates and restores that nested state through A. A
retained-object mutant fails with expected 1 versus actual 9. Schema controls
reject missing result fields and boolean assertion counters.

Evidence: [ownership experiment](../docs/experiments/buffer-ownership.md).
Five receipt tests with mutation tables pass; independent review recheck is clean.

## Verification

| Gate | Actual local result |
| --- | --- |
| Harness/source checks and generated freshness | Passed; 76 source files, zero width violations |
| Harness/tooling suite | 90 tests passed |
| Offline reference/receipt suite | 27-method suite: 25 passed, two engine methods skipped in offline mode |
| Explicit runner controls | Six methods passed on each pinned engine |
| Native fresh-process determinism wrapper | Passed on 4.3 and 4.7.2 |
| Combined native/release-Web matrix | Eight cases, 520 assertions per repetition; R1 446, R2 74 |
| Exact alias-negative controls | Required frame 0/byte 0 failures on both engines and both targets |
| Native/Web equality | Full result records identical for every positive and negative pair |
| Engines/browser | 4.3.77dcf97d8, 4.7.2.ed1daf0bf; Chromium 141.0.7390.37; Linux arm64 |
| Independent Rust vectors | Exact match with pinned rustc 1.94.0 |
| Local environment acceptance | 28 passed, zero failed |
| GDScript lint/format, JS syntax, diff checks | Passed |

The combined receipt is `.cache/reference/results/ownership.json`; all source
and manifest hashes match current files. CI reproduces the experiment on Linux
x86_64, checks the independent Rust fixture and uploads raw receipts/logs.
A hidden `.llm` sample was excluded by Godot Web export; the harness copies it
byte-for-byte into a visible test resource and changes only the preload path.
Native and Web execute the same checksum source and independent vectors.

These are scoped research contracts. No production addon/session, allocation
benchmark, SignalFish integration, other-browser/native-platform matrix or
complete parity is claimed. R3 and subsequent core/protocol tasks remain open.

## Retrospective

Added durable ownership and integer/checksum guidance to determinism, corrected
stale CI descriptions in testing, and recorded the delivery/feedback procedure
at its canonical skill. The retrospective captures false-clean feedback,
complete result schemas, actual snapshot-boundary tests and hidden exports.
Artifact: [representation and shipping](../.llm/retrospectives/2026-10-10-representation-and-shipping.md).
Retro: findings-acted
