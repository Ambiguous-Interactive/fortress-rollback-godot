# Retrospective: 2026-10-25 client correctness

## Work Under Review

- Scope: peer terminal preflight, spectator SDK lifetime guards, replay comparison diagnostics.
- Trigger: production debugging and a new diagnostic API across more than ten files.
- Evidence: deterministic paired regressions, fresh adversarial reviews, source-width and harness checks.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A later driver guard cannot undo input or wire mutation performed by a peer wrapper. | `peer_session.gd` `_step` and `_recover`; `test_peer_recovery.gd` exhausted-counter and BUSY controls. Original code publishes input before request exhaustion. | Extend the existing terminal-preflight rule in rollback-fundamentals. |
| Optional SDK getters can synchronously change the lifetime being checked. | `signalfish_spectator_relay.gd` configuration and gate checks; `getter_lifetime` and `configure_lifetime` paired controls. Original code dereferences detached state or partially installs stale configuration. | Extend networking-transport callback guidance to getters and protocol-info conversion. |
| Fresh review exposed stale identity snapshots, ingress after teardown and overwritten first failures despite passing tests. | Cold SDK-getter probes and expanded lifetime controls; the original stale-player probe passes on main. | Add paired callback-order controls, joint SDK observations and stable-accessor requirements, then repeat review and broad verification. |
| Equal-width comparison hashes do not identify the failed contract. | `replay_player.gd` `_verify_input_digest` and `_checksum_mismatch` previously published only DESYNC plus two hashes; `comparison_domains` and `failure_download` verify the distinction. | Document comparison domains in the API, viewer, reports and networking-transport. |

## Verification

Focused diagnostics and peer recovery pass twice on Godot 4.3 and 4.7.2.
Fresh scoped reviews report no actionable replay or peer findings.
Cold spectator reviews found stale identity, ingress after teardown and first-failure defects.
Clean-addon loading also caught a shared helper signature regression; the Object contract was restored.
The repair requires joint identity/config observations and explicitly stable SDK accessor values,
since bounded repeated reads cannot make arbitrary getter side effects atomic.
Partial broad runs were explicitly terminated and invalidated before the source changed.
Final cold review is clean; its 22-case relay suite passes twice.
Setup-signal controls and both-pin 33-case host/relay suites pass; temporary listeners
now invalidate interrupted setup without acquiring caller playback.
The addon-only package loads all 96 required files on the minimum engine.
Full native, exported ownership and final delivery evidence remain in the machine-local
[session log](../../progress/session-081-client-correctness.md).

## Prune Ledger

- Strengthened existing owning skills instead of creating overlapping skills.
- Corrected integration documentation that described every DESYNC as a game-state mismatch.
- Retained historical replay bytes and explicit live spectator qualification limits.
- Source widths, generated guidance and harness lint were rechecked after edits.

## Outcome

- State: `findings-acted`.
- Follow-ups: original broad acceptance remains in issues #40, #45, #47 and #131.
  Terminal replay checksums remain in #205. No dependency pins or release claims changed.
