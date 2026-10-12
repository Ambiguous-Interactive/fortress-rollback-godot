# Retrospective: 2026-10-12 live fallback

## Work under review

Extend the real exported browser witness with production mixed-path pressure
recovery, default/selected budgets, exact overlap delivery and a disabled-fallback
negative control. New verification capability and repeated review repairs trigger
the full retrospective. Evidence is in
[session 016](../../progress/session-016-live-fallback.md).

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Enqueue counts and unrelated traffic do not prove overlapping delivery. | Fresh review one; two physical-count rejection mutations fail before repair. | Match actual original direct send, remote direct receipt and addressed relay payload bytes. |
| Equal malformed copies can falsely satisfy packet correlation. | Fresh review two; truncated/header/length/sample mutations fail before repair. | Validate captured INPUT layout, roster/session identity and original submitted samples first. |
| Failure prefixes and partial diagnostics do not identify the intended negative-control boundary. | `not-json` and final-confirmation suffixes pass the earlier validator. | Emit structured evidence for every accepted rejection path; reconcile current/last observations and attempt times with expired inactivity. |
| Packet identity includes the connection incarnation. | Fresh review three; header offsets 32 and 33 mutate without rejection before repair. | Validate the exact initial connection incarnation alongside the sender/session. |
| A requested deadline delay can expire before monotonic time reaches the deadline. | Real disabled-control timer fires 0.195449 ms early; deterministic early-callback regression fails RED. | Recheck time inside the callback, rearm early calls, and advance fake clocks through exact expiry. |
| Synthetic pressure and physical loss need separate claims. | Browser bufferedAmount getter changes; ICE and channel state remain physically open. | Name pressure evidence precisely; retain physical loss and SDK lifecycle work in #75/S4. |

## Canonical actions and pruning

Search existing transport/testing guidance before adding instructions. Extend
[networking-transport](../skills/networking-transport/SKILL.md) with physical
packet correlation, independent packet validation and reconciled control evidence.
Extend the existing testing deadline guidance with early-callback rechecks and
advancing fake clocks. Keep these techniques in their existing owning skills.

Replace stale claims that all live mixed-path evidence remains planned in the
canonical context, transport guide and PLAN. Keep physical outage recovery and
the release matrix explicitly open. Earlier session logs and receipts remain
historical evidence; final-source acceptance must use the final receipt.

Verify-on-touch: regenerate skill discovery files, run harness lint/self-tests,
source width 180, witness controls and both pinned exported engines.
No new skill or standalone knowledge entry is needed.

## Outcome

State: findings-acted. Follow-ups remain in #75, S4 and S5; do not close them
from synthetic pressure evidence alone. A fresh curator confirms canonical ownership and scope; its two requested fixes
make incarnation explicit and complete the local verification ledger. Final
delivery gates and exact receipts belong in the session log and linked issue.
