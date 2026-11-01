# Retrospective: client inspection and retryable controls

## Work Under Review

- Scope: peer input preflight, spectator pointer controls, replay provenance.
- Trigger: a demonstrated composed-controller defect and new inspection controls.
- Evidence: deterministic red/green cases and deferred live Xvfb pointer/layout witnesses.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Idle expert-staged input can conflict without an open batch | `examples/peer/match.gd` previously polled and advanced before validating both local samples; `input_preflight` reproduces the permanent failure | Validate effective held/current samples for both endpoints before composed service |
| Invalid user controls and actual runtime failures need distinct recovery behavior | `test_peer_example.gd` expected invalid buttons to poison the match; scene test used the same shortcut | Reject invalid controls for corrected retry; exercise malformed packet delivery to verify real failure remains latched |
| A new result can expose an old suppressed terminal path | PR 296 review and `terminal_partition` regression: stopped peers left composed failure at OK | Latch reset-required status, retire both owned peers and preserve their first cause |
| Batch-end terminal checks allow later packets to replace the first cause | Real GOODBYE and malformed packet orders in `terminal_partition` | Fence after each receive and return before retained queues can be reassigned |
| Provenance and checksum coverage answer different questions | `recording_metadata` retains file identity across failed replacement and playback termination | Label recorded/runtime engines separately; keep identity text outside validation claims |
| Tooltip text assignment does not establish hover delivery or readability | Actual hover on both pins exposed default IGNORE and an oversized popup despite passing property assertions | Use mouse participation and a wrapping plain tooltip; verify live normal/max accepted content |
| Pointer controls need actual viewport evidence | Spectator unit handler tests run during runner initialization | Retain deterministic guards and verify mouse events after live layout settles |

## Actions Taken

Extended the existing user-copy skill with imported-provenance labeling and
bounded plain-text presentation. Existing rollback guidance already requires
preflight before composed side effects, including idle expert input ownership.
Existing testing guidance already requires live pointer checks and distinct
result paths for parallel launchers; both apply directly to this session.
The networking skill now requires terminal fencing after each receive and before
retained-batch restoration. The testing infrastructure reference now explicitly includes tooltip delivery in
its live viewport requirement. No overlapping skill or test runner was created.

## Prune Ledger

- Searched existing style, copy and testing guidance before adding a rule.
- Kept the existing ownership and live-scene rules; current evidence confirms them.
- Replaced misleading invalid-control terminal expectations with actual packet failure.
- Broader source parity, exported spectator and release gates remain in their issues.

## Outcome

- State: `findings-acted`.
- Verification and review receipts are recorded in the machine-local session log.
