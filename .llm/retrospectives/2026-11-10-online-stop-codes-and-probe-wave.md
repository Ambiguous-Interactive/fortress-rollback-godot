# Session 167 retrospective findings (acted)

Date: 2026-11-10. Artifact: progress/session-167-online-stop-codes.md.
Merges: `03a70b1` (#344), `0b67262` (#346). Final main CI: green on `0b67262`.

## Finding 1 — an issue's concurrency sketch missed a process-wide lease

#340's candidate ("ThreadPoolExecutor over the existing commands") was
concurrency-ready on ports and outputs but not on the machine-wide
host-capacity lease: separate probe processes serialize behind it, so the
obvious implementation would have shipped zero wall-time gain while looking
parallel. **Lesson: before overlapping existing commands, audit every lock
they take — including process-wide leases — and design the wave around the
strongest one.** The delivered design takes the lease once per wave and lets
children inherit a name-scoped live lease. Recorded in #340's acceptance
comment and host_capacity's docstring.

## Finding 2 — environment flags must prove their owner, not just exist

The first wave-inheritance gate (`_ours()` true on any ambient
`FORTRESS_HOST_LEASE_HELD=1`) silently disabled contention protection for any
process that inherited the variable. The delivered gate requires the variable
to name the lease record's current owner, so a stray value changes nothing.
**Lesson: an escape hatch scoped only by an environment variable is an
implicit bypass; scope it to verifiable shared state.**

## Finding 3 — fences must cover the spawn window, and tests must pin the
whole branch, not the happy path

The first fence registered process groups after `Popen`, leaving an
unfenceable window that could block a cancelled run while holding the lease;
the reviewer found it, and the follow-up review then found the fix's
self-kill branch had zero test coverage (deleting it passed everything).
**Lesson: every branch added for failure handling ships with a test that
fails when the branch is deleted** — now pinned via a real sleeper spawned
into a mid-window abort in both wave runners.

## Finding 4 — classification widening must pair with the page's own
decision, not just its exit

Generalizing the disposal-abort acknowledgment from "/done + passed" to
"/viewer + any bool result" would have acknowledged aborts beside genuine
mid-run playback failures. The delivered pairing accepts a passing result or
the exact refused-state rejection shape; a playback-step failure stays fatal,
and the zero-simulation evidence stays enforced from the browser report.
**Lesson: when widening a success-paired artifact class, enumerate the page
decisions it may pair with and keep every other decision fatal.**

## Finding 5 — test fixtures that share nested state leak across cases

`REJECTED['state']` was a class-level nested dict; a mutation test's
`state.update(simulations=2)` polluted later cases alphabetically, failing an
unrelated test with a confusing message. Fixed with a deep copy in the report
builder. **Lesson: table-driven mutation tests must deep-copy every nested
fixture they mutate.**

## Finding 6 — suppressed CI output turns a failure into a blind reproduction

The devcontainer verification discarded every command's output, so the
merge-triggered `make test-llm` rejection could not be diagnosed from the run
record. The repair prints a rejected check's whole captured output. The
rejection did not recur, so its root cause remains unidentified — the
diagnostic converts the next occurrence into evidence. **Lesson: every CI
side-check should capture its output and print it on rejection** (the
Repository Guidelines' "add diagnostics" philosophy, applied to the harness).

## Process observations

- Three adversarial review rounds on #344 each found real defects the
  previous round missed (fence completeness, lease scoping, unpinned
  branches); the loop converged to APPROVE with zero revisions.
- Mutation checks caught two vacuous tests before landing (call-site revert;
  deleted self-kill branch) — both reviews' most valuable findings.
- Session length exceeded the two-hour target because merge-triggered main CI
  failed twice and GOAL requires green main before completion; the survey and
  implementation phases stayed within budget, and both repairs were
  evidence-driven single-commit fixes.
