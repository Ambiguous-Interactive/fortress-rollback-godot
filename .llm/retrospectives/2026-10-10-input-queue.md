# Retrospective: 2026-10-10 input queue

## Work under review

New bounded GDScript raw queue, owned-byte tests, actual pinned Rust queue
adapter, strict differential artifacts and scoped source audit.
Trigger: new runtime capability, external source audit and over 300 changed lines.
Evidence: 705 cases and 7961 operations per repetition matched on both pinned
native engines. Five queue unit cases passed twice per process; malformed
artifact controls and a retained-prefix divergence witness passed.

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| Raw tagged-slot lookup can succeed after logical discard, while recoverable history is a session responsibility. | Fact | `docs/input-queue.md`, pinned `confirmed_input`/`discard_confirmed_frames`, corpus wrap cases |
| Raw queue duplicate rejection differs from the ADR's idempotent stalled local submission. | Boundary | `input_queue.gd:add_input`, pinned `add_input_with_reclaim_floor`, duplicate corpus |
| An upstream over-capacity startup gap retains inserted defaults despite rejecting its final input. | Fact | `queue_launch.py:startup_divergence`: Rust acceptance `[false,true,true,false,false]`; Godot `[false,false,false,false,true]` |
| Scope-specific direct APIs avoid treating replay of upstream requests as execution of a Godot queue. | Technique | Rust `__internal::InputQueue` versus actual `FortressInputQueue` on identical bundles |

## Actions taken

The raw/session boundary and capacity rejection procedure now live in the
rollback skill, linked to the detailed source audit. Source-family coverage
remains pending because ordinary, advanced and Rust-only obligations coexist.
The runner records the startup divergence and checks retained bytes; it never
normalizes that difference into an exact-parity claim.

## Prune ledger

Fixed the canonical context and README claim that all runtime components remain
planned. The session engine still remains planned. No separate knowledge file
was added: the contract document and existing rollback skill own these facts.
No source-family status or release gate was weakened.
Verify-on-touch: `make llm-index`, `make lint-llm`, `make test-llm`,
`make lint-source`, `make test-oracle` and both native queue runners.

## Delivery correction

Updating the two completed-review metadata strings with a general JSON rewrite
expanded the ledger from its compact inventory serialization. The intermediate
commit changed 93496 lines. Restoring the original serialization left only the
two intended string changes. `git diff origin/main --stat` verified that the
final ledger diff remained 16 lines. No discovery record or coverage decision
changed. Preserve existing artifact layout for small authored metadata updates;
full inventory regeneration remains a separately verified operation.

## Outcome

State: `findings-acted`.
Follow-up: [global rollback-floor history](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/61).
Session confirmation, prediction-window gating and snapshots remain future work.
