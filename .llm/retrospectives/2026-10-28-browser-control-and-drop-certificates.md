# Retrospective: browser control and drop certificates

## Work under review

Session 105 investigates peer-drop certificates, exported spectator control and
native CLI install diagnostics. Debugging and new browser qualification trigger
this retrospective. Final verification is recorded in the local session log.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A bounded command can still hide the failed phase. | The new installer failure matrix fails all ten phase/error combinations on starting main. | Give each installer call a fixed phase identity and preserve partial diagnostics. |

The installer matrix uses a deterministic subprocess boundary and scripted clock.
Existing real fake-tool tests retain publication retry and successful install controls.
The independent installer review reports no actionable defect.

## Prune ledger

The infrastructure evidence already requires preserving partial timeout output.
Extend that instruction with safe phase identity instead of creating another skill.
No historical release evidence is retired by this diagnostic change.

## Outcome

State: `findings-acted`.

Broader exported spectator gameplay and upstream peer-drop parity remain tracked
by their existing issues. This session does not imply those gates are complete.

## Certificate and browser findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A repeated READY can contradict its first cut/digest while another survivor is pending. | Encoded changed-cut and changed-digest controls fail on starting main; identical retry control passes. Pinned Rust `p2p_session.rs:1744` compares the retained transcript. | Compare the repeated transcript before discarding it; retain the first certificate and fail contradictions. |
| Native HTTP success does not establish browser admission. | Starting-main fixture answers preflight with HTTP 501; a real Chromium fetch fails while the native capability control passes. | Add an exact caller-configured origin and qualify actual cross-origin preflight, roles, admission and acceptance in CI. |

The existing commit suite was staged for browser probes but absent from the
executed inventory. Register its complete ten-case inventory, host preload and
selection together. This reinforces the infrastructure rule requiring aligned
copied, native and browser selections; no additional overlapping rule is needed.

The browser test is a control-service prerequisite. Independent exported Godot
host/viewer gameplay, actual seated transport and remaining fault cells stay in
issue #245. Native CLI and HTTP fixture changes do not claim a production
identity service or new supported browser release.
