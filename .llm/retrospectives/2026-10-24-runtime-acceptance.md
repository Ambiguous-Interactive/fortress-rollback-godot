# Retrospective: runtime acceptance

## Work under review

Driver/expert encoded peer comparisons, full-roster replay observations and
production spectator traces checked by the pinned upstream model.
Trigger: new verification capabilities and a review finding in an acceptance gate.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A named sparse workload can execute no validation and still qualify. | `scripts/oracle/test_replay.py` disables validation, makes checksums dense and checks the predecessor of the interior failure; all old controls accept those changes. | Independently require exact SAVE/ADVANCE schedules; extend the existing oracle-validation reference. |
| Model checking the upstream spec does not observe the product. | The prior `spectator_launch.py` accepted an unused engine argument and reported that Godot was not projected. | Feed actual initial and post-states through pinned Init/Next, with skipped-input and callback-order controls. |
| Numeric equality does not validate trace types. | `test_spectator_runtime.py` rejects boolean callback values, malformed rings and duplicate capacity workloads. | Apply the existing strict-schema procedure; add no duplicate rule. |
| Final game bytes can conceal reordered original rows. | Swapping rows 10/11 in the peer reference game changes an intermediate prefix but preserves the final state. | Require independent corrected callback prefixes, following the existing temporal-mutation rule. |

The replay acceptance regression fails against the original validator and passes
after repair. New runtime gates retain precise limits in the replay and spectator
documentation; no new browser transport or complete feature-parity claim follows.
Both changes receive fresh adversarial review and source-bound pinned-engine runs.

## Prune ledger

Searched testing references, knowledge and review guidance before writing.
Extended the existing oracle-validation home instead of creating another skill.
The strict numeric schema and initial/post-state projection procedures already
exist there and remain correct. Older retrospective records include an archive;
their incident evidence is not superseded by this session, so none was deleted.
No production defect was established by the runtime audits; no speculative fix
or new unsupported feature was added.

Verify-on-touch: `make llm-index`, `make lint-llm`, `make test-llm`,
`make test-oracle`, and the pinned runtime gates.

## Outcome

State: findings-acted.
Broader acceptance remains in issues #40, #45 and #47; live spectator work remains in #131.
