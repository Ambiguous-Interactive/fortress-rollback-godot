# Retrospective: 2026-10-13 resume expiry

## Work under review

Online retained-output expiry, bounded handshake timeout publication, and actual
Chromium page-thread suspension on both engine pins. Trigger: debugging incident
and new browser lifecycle evidence. Evidence:
[session 019](../../progress/session-019-resume-expiry.md), #85, native regressions,
source-bound handshake and exported-browser receipts.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Caller-owned output pressure suppressed elapsed-time polling; valid stale delivery revived expired gameplay. | Old caller regression consumes two buffered packets and advances frames 92–94 after expiry. | Strengthen the existing [networking timeout rule](../skills/networking-transport/SKILL.md) with expiry-before-receive ordering. |
| The older mixed-path verification caller retained the same polling bypass. | Its actual native host/peer clock assertion fails with old source and passes both pins after repair. | Sweep and repair that caller; retain independent cold review and full browser gates. |
| A retry refused before commit also erased its independent timeout diagnostic. | One-token/one-packet tests report zero events before repair, exactly one afterward. | The same canonical rule now separates deadline diagnostics from unsent retry state. |
| A successful CDP lifecycle command did not establish suspension of this active game. | Requested 750 ms lifecycle freeze produces at most a 96 ms observed gap; acknowledged debugger pauses produce 767–774 ms and 2.52 s gaps. | Add one scoped measured fact to [transport tooling](../knowledge/transport-tooling.md). Require actual pre/post clock/frame evidence. |
| Parallel native execution and export bootstrap both owned the editor cache. | The browser bootstrap fails with ETXTBSY before execution. | Follow existing testing serialization guidance; final export starts after native execution ends. No duplicate rule added. |
| A Node pause timer returned before the requested duration. | Hosted expiry flow stops frames 121/122 correctly, but the parent records 2499802 µs against 2500000 µs. | Await monotonic elapsed duration and extend the existing testing timer rule; a controlled early callback fails before repair and passes afterward. |
| Isolated pressure tests missed combined diagnostic and link-order pressure. | The minimum two-slot handshake bank revives a buffered final reply; a fresh pressured first link suppresses the overdue second link. | Add both public-boundary regressions and strengthen the networking pressure rule. Drain and repoll before buffered receive; poll all eligible links. |

## Prune ledger

Searched existing skills, knowledge and retrospectives first. Expanded one
networking invariant instead of introducing another skill. Existing cache,
terminal-frontier and source-freeze guidance remains supported. No old entry is
retired: debugger suspension evidence does not supersede broader browser limits.
Verification: source lint, harness lint/index/stubs and harness self-tests.

## Outcome

State: `findings-acted`. Broader browser lifecycle and restoration acceptance
remains in #38/#75; release compatibility remains in #39.
