# Retrospective: 2026-10-13 online failure cleanup

## Work under review

Scope: terminal online caller cleanup, synchronous failure guards and physical
signaling outage/fresh-room browser evidence. Trigger: debugging incident and
new lifecycle verification capability. Evidence is retained in
[session 020](../../progress/session-020-online-failure-cleanup.md).

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| Cleanup after Leave can hide an open socket while a failed game is idle. | Technique | Original `FortressOnlineLobby._fail` detaches Match without closing client; failed ticks return before polling. Native red and original-source exported cleanup gate reject this behavior. |
| A successful SDK return does not override a terminal signal emitted during the call. | Existing invariant | Ready regression reproduces overwritten failure text and `has_readied=true`; setup and poll cases require first-reason preservation. |
| Guarded detach during a send callback can mark failure while leaving queues retained. | Technique | Fresh adversarial review traces the actual SDK binary-send failure through the busy relay/fallback detach branches; cleanup must run after the active operation unwinds. |
| Closing one expired peer can deliver an SDK departure callback before its partner services elapsed protocol time. | Existing invariant | The first repaired browser run closes every connection but fails its strict clock gate; the exact-deadline/overdue native reproduction records stale protocol time before SDK terminal callbacks. |
| Separate Playwright init-script registrations do not guarantee dependency order. | Technique | Pinned Playwright's API contract and reversed actual initializer execution reproduce a missing socket inventory; one controlled initializer establishes ordering. |

## Actions taken

The transport skill now requires physical signaling closure before user cleanup
and closure-only service while preserving callback-owning objects. Its existing
callback lifetime rule already covers first-failure precedence; that guidance is
retained without duplication. The same skill requires a cleanup retry when busy
adapters defer queue release. Browser acceptance extends the existing playable
witness rather than adding a separate smoke-only connection test.
The existing deadline rule now explicitly includes SDK callbacks. The browser
clock validator remains unchanged; the caller's service order is corrected.
The testing skill now requires dependent browser observers to share one ordered
initialization script. Its existing constructor/channel-policy guidance remains
intact, and a controlled Node test verifies actual observer construction.

## Prune ledger

No guidance is retired: existing adapter lifetime fences and host-clock rules
remain applicable. The online guide now describes automatic failure cleanup;
server-process restart and transparent recovery remain explicitly unproved.
The devcontainer's 100-column ruler is corrected to match the repository's
180-column editor/formatter/source-lint contract.

## Outcome

State: `findings-acted`. Full verification and final review/delivery evidence
are recorded in the session log and linked issue before completion.
Follow-ups remain under #38, #75 and #39; this outage witness does not close
their broader lifecycle or release acceptance.
