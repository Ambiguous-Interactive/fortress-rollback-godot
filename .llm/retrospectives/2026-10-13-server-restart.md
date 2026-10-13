# Retrospective: 2026-10-13 server restart

## Work under review

Scope: actual owned server death/restart in the playable online example,
foreign-packet rejection, shared session clock preservation and SDK callback
lifetime fences. Trigger: new capability, production defects and review rework.
Evidence: session-021 receipts and mutations; final delivery evidence lives in
[the session log](../../progress/session-021-server-restart.md).

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| Foreign endpoint rejection can still mutate the shared facade clock and service controls. Same-time samples hide this. | Technique | `core/peer_session.gd` `_receive`; later-clock red changes 666680 to 666681 µs; eight repaired adapter cases pass |
| Callback lifetime tests need real invocation, owning-target retention and originating-owner selection. A standard Callable does not retain a RefCounted target. | Technique | `browser/online_bridge.gd` capture/replay; zero-call browser receipt rejected; removing target ownership fails four actual capture assertions |
| A process restart needs owned exit/readiness evidence independent of sockets. Graceful SIGTERM did not finish within ten seconds; intentional SIGKILL exits -9. | Technique | `browser/owned_server.py`; real subprocess controls; browser process event inventory |
| Browser bootstrap overwrites shared editor paths, so native tests need independently verified executable copies during overlap. | Existing technique | Initial ETXTBSY receipt; serialized browser bootstrap and separate native executable paths |

## Actions taken

| Action | Canonical home | Verification |
| --- | --- | --- |
| Preserve foreign-rejection facade state and fence reusable callback lifetimes. | [Networking transport](../skills/networking-transport/SKILL.md) | Native later-clock/callback tests and exported old-room delivery |
| Require later clocks, retained targets and exact owner selection in rejection/replay witnesses. | [Testing](../skills/testing/SKILL.md) | Actual capture mutation and strict browser callback inventory |
| Require owned process exit and fresh live readiness; bind browser records to actual handles and source/config hashes. | [Networking transport](../skills/networking-transport/SKILL.md), controller and process tests | Actual exit, closed endpoint and fresh readiness control |
| Preserve shared-executable guidance and use it for final gates. | Existing testing skill | Final native executables have the pinned byte hashes |

## Prune ledger

No stale correctness claim was retired. Existing engine-double/constructor
instructions were condensed while preserving their public-interface and exported
verification obligations, leaving the testing skill below its 300-line cap.
No duplicate skill or knowledge entry was added. Old socket-outage evidence remains
valid and separately gated; it was not relabeled as server-process evidence.

## Post-merge finding

Main CI's altered-restore control legitimately reaches DESYNC before capture.
The validator's playing-only assumption rejects that intended result before
canonical comparison. The retained CI peers are frame 44/confirmed 36 (playing)
and frame 36/confirmed 36 (failed with code 18). The typed-cause repair still
requires independent altered bytes at frame 3 and rejects unrelated failures.
This technique is added to the existing testing guidance. The exact red/green
record and required second-PR exception are recorded in the session log and #93.

## Outcome

State: `findings-acted`.
Transparent reconnect, ICE restoration, SDK replans, relay congestion and the full
browser matrix remain under existing issues #38, #75 and #39.
