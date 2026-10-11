# Retrospective: 2026-10-11 SignalFish membership

## Work Under Review

- Scope: optional SDK-independent UUID membership and plan adapter, pinned SDK
  integration witness, package clean-load controls and CI wiring. The review
  snapshot `/tmp/session-012-review-current.diff` contains 11 changed files;
  documentation and harness curation continue outside that snapshot.
- Trigger: new subsystem, external SDK archaeology, package-audit incident and
  an independent review finding requiring repair.
- Evidence: [session record](../../progress/session-012-signalfish-membership.md),
  actual source inspection and the local receipts below. Receipts identify
  their engine and pin; they establish local Linux ARM64 execution only.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Loading gameplay-reachable code does not prove optional SDK independence. Every shipped runtime script must load without the SDK. | technique | `scripts/reference/test_package_audit.py:62` injects an unused missing-SDK preload; `.cache/reference/session-012-package-red.log` reports `AssertionError: ValueError not raised`. |
| 2 | Validating a session plan does not fence every SDK authority path. Additive peer callbacks can create connections outside the approved roster, including after partial initialization failure. | technique | Pinned SDK `addons/signal_fish/webrtc/sf_webrtc_mesh.gd:269` calls `_open_peer` from `new_peer` without roster validation; `:360` returns after initialization failure. Candidate adapter `:32` subscribes to plans before mesh attachment but originally omitted `new_peer`. |
| 3 | Independent identity goldens and targeted mutations expose plausible self-consistent mistakes. | technique, reinforce | `tests/unit/test_signalfish_membership.gd:62` has an independent Python SHA256 roster/config golden; `:77` has a known FNV collision fixture. `.cache/session-012/mutate_membership.py` separately removes roster hashing, numeric collision rejection and lifetime fencing. |
| 4 | Real SDK integration can be deterministic without a live server, but its transport boundary must be named precisely. | technique, reinforce | `.cache/reference/results/sdk-final-4.3/signalfish-sdk.json` and `sdk-final-4.7.2/signalfish-sdk.json` report 70 confirmed two-peer steps through the pinned decoder and public binary transport with an injected wire. |
| 5 | A binary sender signal without server epoch metadata cannot establish transport-incarnation attribution. | boundary | Existing SDK public binary attribution and [membership limits](../../docs/signalfish-membership.md); the owning networking skill preserves this limit. |

## Evidence Provenance and Boundaries

The unchanged baseline receipts `.cache/tests/session-012-baseline-4.3.json`
and `session-012-baseline-4.7.2.json` pass 107 cases before the implementation.
The focused receipts `.cache/tests/session-012-signalfish-unit-4.3.json` and
`session-012-signalfish-unit-4.7.2.json` pass eight cases with 740 assertions per
in-process run, repeated inside each of two fresh processes. These receipts
precede the independent additive-peer finding and cannot certify its repair.

Each of the three mutants fails at its named assertion on both engine pins.
The collision mutant also prints repeat-divergence because failed assertions
contain distinct allocated-object IDs; its direct rejection/failure-state
assertions establish the intended failure independently of that extra error.
These are new-feature negative controls, not claims of historical regression
triple proof.

Package controls pass after repair in
`.cache/reference/session-012-package-green-4.3.log` and
`session-012-package-green-4.7.2.log`. The clean-load gap predates available
history: the red log proves the old audit accepted the defect, without claiming
a passing pre-regression revision. The stronger audit also exposed an actual
Godot 4.3 parse failure in the candidate's original hashing API, recorded in
the session record.

SDK receipts pin revision `db7d30f228d8d564adcb2eb38d5983bf6b9877ac` and archive
digest `0854f8c778a118defe95bd8887e227c8bc8c194c54d2e501c6d74094fa43ec12`.
The probe inventory checks executed addon/probe sources before and after use
(`scripts/reference/signalfish_probe.py:67`). The injected witness exercises
genuine SDK decoding, state, mesh attachment, signals and binary send/receive.
It does not prove a live SignalFish server, real WebRTC channels, browser
behavior, reconnect recovery or a shipped byte-delivery adapter.

## Actions Taken

| # | Action | Canonical home | Verification |
| --- | --- | --- | --- |
| 1 | Strengthened the existing optional-SDK procedure with an unused missing-import control. | [networking transport](../skills/networking-transport/SKILL.md) | Local red/green package controls above; final harness checks required below. |
| 2 | Replaced plan-only wording with auditing every mesh-authority path, explicitly additive peers after partial initialization failure. | Same networking skill | SDK source inspection above; implementation regression repair and final reruns are separate delivery requirements. |
| 3 | Kept genuine SDK witness, identity comparison, lifetime fencing and epoch limits in that single existing procedure. | Same networking skill | Existing focused, mutation and SDK receipts above establish their stated boundaries. |
| 4 | Recorded optional membership as a seam while keeping real transport/browser support planned. | [context](../context.md) | Checked against actual adapter status and witness limitations. |

## Prune Ledger

- Searched existing skills, knowledge and retrospectives before writing; no
  competing optional-SDK procedure existed. Updated the networking skill rather
  than creating another skill or a duplicate knowledge entry.
- Fixed plan-only advice at its authoritative source. Retained the real
  transport/browser release limits and the distinct gameplay versus diagnostic
  trace guidance; this session did not invalidate them.
- Twelve retrospective files existed before this artifact, below the current
  consolidation threshold. No unrelated retirement was justified.
- Verify-on-touch: root passed `make llm-index`, `make lint-llm` and
  `make test-llm` after the final curation edit, plus `make lint-source`.

## Outcome

- State: `findings-acted` — durable guidance corrected and evidence boundaries
  recorded. This state describes curation, not release or merge status.
- Follow-ups: the separate evaluator completed the additive-peer repair with
  real SDK matching-retry and identity-mapping regression controls on both pins.
  A final fresh-context review passed the nine seam cases, SDK witness and package
  controls on both pins with no findings or source drift. Root passed all 116 unit cases and determinism suites on both pins with
  the explicit 120-second CI budget, then reran SDK/package witnesses. Root records
  current-head CI, feedback and delivery in
  the linked S1 issue. Browser and live transport gates remain separate roadmap
  work; no pending CI or live transport check is claimed passed here.

Retro: findings-acted
