# Retrospective — session 209: one publication seam for the drop-barrier controls

PR #422 (issue #419).

## What happened

Issue #419 came from the #418 adversarial review: the drop-history fixture
recorded COMMIT and report publications by diffing an endpoint's outbox inside
the barrier's `_send`, but PREPARE bypassed that hook, and the donor-plan
prepare bypassed it twice — `peer_drop_transfer.service()` called the endpoint
directly. A prepare published but never routed therefore produced no emission,
no missing receipt and no fixture failure. The proposal's emission order was
also drawn from the shared counter instead of paired with its publication, and
two counter draws lacked the `> 0` guard the other kinds use.

Production publication now funnels through one `FortressPeerDrop._publish`
seam; the barrier, the value backfill and both donor-transfer sends use it. The
test drop subclass overrides `_publish`, records PREPARE beside the other
shapes, and the fixture pairs every recorded publication with routing through
the existing FIFO `take()`. Counter draws go through a guarded helper. A new
donor-plan-targeted mutant drops the plan before `take()` and fails the
fixture's own completeness assertion. The corpus also gained a real
`unequal-lost-prepare` scenario: the pinned Rust model drops the first 0->1
`DropPrepare`, and the comparator reconciles the lost proposal, its
byte-identical retry and the unchanged cut.

## Durable lessons

1. **Hook the lowest common production dispatch, not the convenience wrapper.**
   A test interception above the real send seam silently misses every path that
   bypasses the wrapper. Moving the seam to the one function that every payload
   shape calls made the donor plan observable and left the shipped behavior
   unchanged.
2. **A routing mutant and a loss control are different instruments.** Drop the
   packet before `take()` to prove the fixture notices a publication that never
   routed; drop it after `take()` to inject a legitimate loss that the
   emission/loss/receipt accounting must reconcile. Using one placement for
   both hides whichever failure the other was meant to catch.
3. **Trace schema growth reaches more files than the obvious three.** Adding
   `lost_prepare` touched the Rust model, the fixture, the comparator schema,
   the loss-count checks, the retry evidence, the order-scaling bank lists and
   the negative-control enumeration. The corpus's "negative control survived"
   gate caught the missing pass-through on the first run.
4. **A single-shape mutant can be weaker than the issue it closes.** The first
   mutant dropped the opening proposal, which only proved the `_send` path; the
   review's advisory pushed it to the Stage.HISTORY donor plan, the path that
   actually bypassed the old observer.
5. **Bot type errors need evidence, not code churn.** The final-head review
   claimed `body.contains_key` cannot compile; `body` is a
   `&serde_json::Map`, the pre-existing `DropCommit` check uses the same method,
   and the pinned build finished. A compile transcript and a binary run settled
   the thread without weakening the code.
6. **Scope strings are claims.** The receipt's "combined with donor-data loss"
   wording initially implied a prepare-loss-plus-history scenario that did not
   exist; the review caught the overclaim, and the wording now matches the
   scenario table.

## Verification

- `make drop-history-probes GODOT=godot` green on 4.7.2: 17 scenarios x 2 fresh
  repeats, 1137 negative controls, including `observed_unrouted_prepare` and six
  prepare-loss controls; receipt binds clean tree `efab1832`.
- Red-green: `--unrouted-prepare` exits 1 with exactly the completeness
  diagnostic and exits 0 with no failures when PREPARE is removed from the
  recorded shape set.
- `make gate` green on the final tree; `make lint-source` 552 files, 0
  violations at 180 columns.
- Full head CI green: Gate (changed suites on 4.3, harness, reference/oracle
  negative controls), Reference Baseline, Devcontainer Verify, OpenAI review 0
  findings before the final false positive.
- Adversarial fresh-context review: one minor (scope overclaim) and two
  advisories fixed in one round, then re-reviewed clean apart from a docs count.
- Merged through the queue from scanned head `36f79eed` as
  `181fa8c4e9f70e3595b5256568e23439ab291577`; grouped Gate and Reference
  Baseline passed on the candidate.
- Issue count: #419 closed; #48, #166 and #188 carry the lost-proposal coverage
  comment. Bugbot was unavailable again (on-demand usage not enabled, #276), so
  that coverage is recorded as unavailable, not clean.
