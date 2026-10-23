# Retrospective: 2026-10-23 spectator and replay boundaries

## Work Under Review

- Scope: authenticated spectator startup, confirmed-only spectator API and paused replay validation.
- Trigger: three reproduced production bugs under issues #131, #29/#47 and #45.
- Evidence: failing and passing native runner receipts, original-input state comparisons and fresh adversarial reviews.
  Local commands and receipts are recorded in `progress/session-046-spectator-and-replay-boundaries.md`.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Startup offers bypassed the payload path's expiry, monotonic clock and active-request checks. | `spectator_stream.gd` routed OFFER directly to `_receive_offer`; the new `offer_lifecycle` case recorded 18 assertion failures before repair. | Startup now polls before changing agreement or liveness; the transport skill requires offer/retry boundary coverage. |
| Inherited player freezes could replace a spectator's confirmed host bytes. | `mesh_mutators` produced frame-one states 15 and 42 instead of 18, and exported substituted inputs. | Both freeze APIs return `UNSUPPORTED`; the rollback skill names freezing in its inherited-mutator audit. |
| Paused validation checked state checksums without checking the selected input digest. | `paused_input_integrity` recorded 66 failures before repair, including missing failure evidence and extra checksum coverage. | Digest checks precede snapshot/coverage publication; the rollback skill covers checksum-free paused inspection too. |

## Prune Ledger

- Updated existing transport and rollback guidance after searching their current contracts; created no overlapping skill.
- Tightened the existing spectator mutator rule rather than adding a second conflicting policy.
- Kept the existing broad issue acceptance gates open: local repairs do not establish live relay or release parity.
- The server spectator-routing dependency is now closed upstream, but the pinned server and SDK need separate qualified upgrades.

## Verification

- Repeated fresh-process tests on Godot 4.3 and 4.7.2.
- Updated the exported ownership probe's case inventory for the three new regression cases.
- `make llm-index`, `make lint-llm`, `make test-llm`, `make lint-source` and the session CI gates.
- Fresh-context adversarial review of replay and spectator diffs; delivery evidence belongs to the session log and linked issues.

## Outcome

- State: `findings-acted`.
- Follow-ups: #131 retains SDK/server upgrade and real spectator relay evidence; #45 and #29/#47 retain their full acceptance gates.
