# Session 026 — Peer notices and canonical downloads

## Scope and baseline

Started 2026-10-16 at 04:54 UTC, with a two-hour session limit.
Main is clean at `9ef3fa5ad8dee3dd6fd53c80a83be1c4fb547124`.
Authenticated current-state reads find no open PRs and all three main workflows
successful. The previous goal turn made progress by landing PR #101.
This session attempts three open user-facing issues: peer presentation (#40),
canonical downloads (#42), and safe transport lifetimes (#38).
New defect #105 records the SDK reentry reproduction and acceptance.

## Peer completion (#40)

`FortressPeerSession.step_completed(code, frame_before, frame_after)` emits the
final outer result after game callbacks and peer control processing. Configured
stalls, not-ready attempts and errors emit once. Unconfigured and recursive BUSY
attempts emit nothing. The peer mutation guard remains held through handlers;
publication drains remain reserved until `step` returns. No rollback algorithm,
simulation request order or protocol operation changed.

The new notification suite fails at the initial revision because the signal is
absent (`.cache/tests/session026-notice-red.json`). After implementation it passes
normal peer advancement, actual stalled correction, terminal results, explicit
callback failure and attempted public mutation from handlers. A fresh adversarial
review reports no actionable findings. This is a new capability, so there is no
earlier passing pre-regression implementation.

## Local canonical downloads (#42)

The online scene defaults to observation-only diagnostics. A checkbox before Ready
enables 120 local canonical frames with the actual game seed and version. Ready
freezes the choice. The same browser download/native clipboard report then includes
the existing bounded trace; SDK configuration, credentials and room/player identities
remain excluded. No standalone replay command is invented.

The checkbox/configuration tests fail before implementation and pass afterward.
The real online browser witness selects capture only on page zero of its first
clean room; nine other clean-room downloads stay payload-free. Validation checks
the complete contiguous window, payload/export bounds, checksums, strict schema,
and at least fifty corrected confirmed states and original inputs. Download
collection still runs only after physical teardown with browser storage unavailable.

A fresh reviewer found that historical applied predictions can remain status two
after matching late actual input. Requiring status one rejected correct history.
The new status-two control fails before repair and passes afterward; validation
compares original bytes without rewriting the historical status. Fresh re-review
is clean. Existing temporal and corruption controls retain their original rejection
boundaries. Both diagnostic/probe Python suites pass all 22 tests.

## SDK lifetime reentry (#38/#105)

Symptom: room loss during mesh attach is overwritten by awaiting-plan state;
room loss during relay teardown causes two detach calls and an apparently valid
relay route. A plan conversion can also release membership before parsing resumes.
The red receipt `.cache/tests/session026-replan-red.json` records these failures,
including the null-membership script error. These paths existed in the initial
adapter; no known earlier passing revision exists for the unsupported reentry cases.

The adapter now publishes provisional attach ownership before SDK calls, preserves
initial synchronous plans, marks the mesh released before teardown, and checks the
lifetime revision after callbacks. Fresh review then reproduced refusal teardown
accepting a nested relay plan and outer detach clearing replacement ownership.
Two further regressions fail in `session026-replan-review-red.json`; teardown guards
repair both in `session026-replan-review-green.json`. All six focused cases pass.
Independent fresh re-review reports no findings. Existing valid relay switching
and explicit restart boundaries remain required by the full suites.

## Verification and delivery

Both initial online browser receipts pass with all ten clean rooms, twenty real
downloads, two opt-in canonical windows and the intended corruption controls.
Visual inspection then finds status text overlapping the playfield after the
checkbox adds a row. The playfield now follows the measured status area. The
initial passing receipt is superseded by a fresh final-source browser invocation.

The 4.3 unit category passes all 246 cases through both repetition layers. An
incorrect combined integration invocation hits its 120-second watchdog; the
remaining repetition is stopped and its failure receipt retained. The documented
CI entry point runs these cases separately, with 180 seconds for `default_single`
and 120 seconds for each other case. The corrected invocation keeps those exact
workloads and deadlines. No test or gate is relaxed. A stale unit-budget sentence
in the runner guide is corrected to match CI's existing 180-second command.

Source-width lint and formatting pass. All 89 reference Python tests pass with
three environment skips, all 56 oracle controls pass, all 106 harness cases pass,
and all 57 Node browser controls pass. Both native engine inventories and the
actual source-bound online browser receipts are in progress. Final review,
current-head CI, complete feedback scans, guarded squash merge, local sync and
merge-triggered main CI remain required; later evidence belongs here or in the PR.

## Retrospective

The [retrospective](../.llm/retrospectives/2026-10-16-peer-notices-and-capture.md)
updates the owning rollback skill with the execution-status/confirmation distinction.
Existing callback/lifetime guidance already covers the other findings.
Stale public-guide statements were corrected at their source.
Retro: findings-acted.
