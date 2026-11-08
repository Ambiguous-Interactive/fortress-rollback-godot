# Retrospective: parallel negative controls and receipt identity

## Work Under Review

Session 160 landed the process-parallel negative-control runner, split the
ownership rejection suite into concern files, swept the six oracle launchers
onto the two-boundary receipt contract, and gathered measurement evidence for
#117 plus an instrumented spectator witness batch for #322. PR #333 squash
merged as `5118de2`.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Sharding by file cannot beat a single dominant file. | First parallel run: 7m28s versus 8m49s sequential because `test_ownership_probes.py` alone took 447.7s of summed process time. | Split the suite along existing concern boundaries; runner wall fell to 3m21s, then 2m29s. |
| Extraction scripts move more than the named block. | The line-range extraction copied four test methods into `ownership_rejection_fixture.py`, so every subclass inherited and re-ran them (16 redundant executions). CodeRabbit caught it; static definition counts missed it. | Count with `TestLoader().discover().countTestCases()` against the sequential `Ran` total (299) instead of counting `def test_` occurrences. |
| Moving identity capture earlier changes rejection contracts. | `test_fetch`'s launcher-argument control went red: capturing git identity before argument validation turned clean exit-2 rejections into exit-1 git crashes outside a repository. | Capture identity after argument validation but before the first child spawn; keep the red control green again. |
| Hook-provided `GIT_*` overrides redirect `git` reads. | CodeRabbit finding on `git_identity`; the fixture environment already strips these variables for the same reason. | Strip `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY` and `GIT_ALTERNATE_OBJECT_DIRECTORIES` inside `git_identity`. |
| `assertIn` against a StringIO iterates lines, not text. | The worker-crash control failed although the captured output contained the expected line; `in` on a StringIO checks membership over lines. | Assert against `output.getvalue()`; the paired isolated repro passed only because it used the string. |
| Sequential baselines must precede optimization claims. | The 8m49s sequential measurement (299 cases, 10 skips) was captured before any runner change, so the parallel comparison is like-for-like on the same tree. | Keep recording before/after pairs with tree state, machine and load conditions in `docs/reference/jobs.md`. |

## Actions Taken

- Runner aggregation synthesizes a failed result for a crashing worker, so
  partial results can never publish a success summary.
- Runtime discovery count (299) is now the parity gate for suite splits; the
  definition-count check remains only as a sanity aid.
- `docs/reference/jobs.md` records the measured lever and its critical path.

## Prune Ledger

| Pruned | Reason | Date |
| --- | --- | --- |
| `.cache/scratch/session160` measurement logs | machine-local; cited numbers live in the issue comments, PR body and docs | 2026-11-08 |
