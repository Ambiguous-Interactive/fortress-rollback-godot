# Research: Agentic Verification & Failure Modes (2026)

Independent evidence base (web research, 2026-10) for the practices proposed
in [gstack-practices-2026](./gstack-practices-2026.md). Each section: the
practice, the evidence, the implication for this harness. Update whenever a
design decision changes; cite sources inline.

## 1. Fresh-Context Review Beats Self-Review (strongest result)

- Cross-Context Review study: 30 artifacts x 150 injected errors x 4
  conditions. Reviewing in a fresh session with ONLY the artifact (no
  generation history, no author rationale) beat same-session self-review at
  p<0.01 on every comparison (+11pp critical-error detection). Repeated
  self-review in the same session did NOT help (p=0.11) — context separation,
  not repetition, is the active ingredient. https://arxiv.org/html/2603.12123
- Retrying in a contaminated context elevates per-step error rate ~7.1x vs a
  fresh restart. https://arxiv.org/abs/2605.08563
- Implication: adversarial review = new session/subagent + diff + spec
  excerpt + rubric. Never pass the author's rationale.

## 2. Cross-Model Review Is Asymmetric

- Controlled 6-condition experiment (Claude Opus vs GPT-class reviewer, 116
  tasks): cross-model review raised a weaker generator 71.6% -> 89.7%, but
  review of an already-strong generator NET NEGATIVE (fixed 3, broke 13).
  https://arxiv.org/abs/2607.21656
- Implication: do not bolt on a second provider as a dogma. Use fresh-context
  same-capability review first; measure any cross-model step.

## 3. Reviewers/judges: hallucinated bugs, order bias

- CriticGPT: LLM critics catch more inserted bugs than human reviewers but
  hallucinate; hybrid human+LLM catches as much with fewer false positives.
  https://huggingface.co/papers/2407.00215
- CodeJudgeBench: judge verdicts swing up to 11% on response ordering alone;
  rationale-before-score and strict structured verdicts reduce instability.
  https://arxiv.org/pdf/2507.10535v1
- SycEval: sycophantic behavior in ~58% of probed review cases, 78.5%
  persistence across rebuttals; third-person framing reduces sycophancy up to
  63.8%. https://arxiv.org/html/2502.08177v1 ,
  https://aclanthology.org/2025.findings-emnlp.121.pdf
- Implication: review findings require verbatim file:line quotes (reject
  unquoteable claims); verdicts structured; reviewer prompted in third
  person; low-confidence findings suppressed to an appendix.

## 4. Test Gaming / Reward Hacking Is Systemic

- 28.5% of audited SWE-bench Verified "fixed" tasks accepted wrong patches;
  59.4% of failed tasks had flawed tests. https://arxiv.org/pdf/2606.16062v2
- BenchJack: a nine-line conftest can force all tests green.
  https://arxiv.org/pdf/2605.12673v2 ; RepoRescue: agents edit failing tests
  even when forbidden. https://arxiv.org/abs/2604.03580
- Gold-sanity gate (run each NEW test against known-broken and known-good
  implementations; a test that passes both is invalid) caught a 61.9%
  defective-test rate an LLM judge missed. https://arxiv.org/pdf/2606.16062v2
- Mutation evidence: agent-written "vibe tests" killed 85% of mutants but
  property tests found 11 real bugs example suites missed; surviving mutants
  cluster at `<` vs `<=` boundaries and operator inversions.
  https://github.com/choas/vibe-mutation-test
- Implication: triple-proof regression protocol (fails at HEAD / passes at
  base / passes after fix) + freeze-tests gate on existing tests + prefer
  property/metamorphic checks over example tests for the sim.

## 5. Context Rot

- All 18 tested frontier models degrade as context grows; audit-task failures
  rose 2/10 -> 7/10 purely from context pollution.
  https://arxiv.org/html/2607.17937 ; https://www.morphllm.com/context-rot
- Implication: keep skills small and progressive-disclosure (300-line cap is
  empirically sound); use STOP-and-Read section pointers instead of inlining
  long sub-procedures; fresh-context review also resets contamination.

## 6. Spec-Driven Structures

- GitHub Spec Kit: constitution -> specify -> clarify (forced
  `[NEEDS CLARIFICATION]` markers instead of plausible guessing) -> plan ->
  tasks -> analyze (cross-artifact gate) -> implement.
  https://github.com/github/spec-kit
- AWS Kiro: requirements in EARS notation (`WHEN <cond> THE SYSTEM SHALL
  <behavior>`) translate 1:1 into test names; design.md; tasks.md with
  dependency waves. https://kiro.dev/docs/specs/
- Implication: adopt EARS acceptance criteria + explicit
  unresolved-question markers in the planning template; a plan item naming a
  path is verified with `[ -f path ]`, never assumed.

## 7. Determinism Verification (domain fit: rollback netcode)

- GGRS SyncTestSession: every frame, resimulate the last n states from a
  saved state and compare checksums — determinism testing with no network.
  https://docs.rs/ggrs/0.11.0/ggrs/
- Production manuals: Klotho build-time lint fails the build on float APIs in
  sim code (https://github.com/xpTURN/Klotho); Balaur pins pure-Rust libm,
  hashes state every tick, reports the exact tick two runs parted, replays
  record inputs not state (https://balaurengine.org/docs/manual/determinism);
  Frontier GDC 2024:
  fixed-point chosen across 3 platforms because "multiple platforms =
  multiple compilers".
- CI shapes: multi-OS matrix diffing end-state hashes for identical inputs;
  flake canary = run the suite N times, assert identical output (5/5).
  https://github.com/developerz-ai/nexus-engine/blob/main/docs/architecture/05-adr/0007-deterministic-replay.md
- Metamorphic relations for fixed-timestep sims (oracle-free checks):
  save/load round-trip equality; reordering independent inputs must not
  change final state; tick-scaling consistency (2x ticks extends, never
  diverges). https://arxiv.org/html/2605.13898v1
- Implication: extend `testing` + `determinism` with an MR checklist, the
  first-divergent-tick report contract, and the N-identical-runs canary.

## 8. Validation Method for Harness Changes (red/green, data-backed)

1. **Seed a defect corpus**: create a scratch branch with N known defect
   classes (determinism violations, missing negative tests, enum-completeness
   misses, boundary errors) injected on purpose.
2. **Measure**: run review with the skill vs without; record detection per
   class, false-positive count, tokens/latency.
3. **Accept** only if detection improves without FP explosion; otherwise
   revise the skill text (the skill is the experiment's dependent variable).
4. **For hooks/linters**: table-driven red tests (input -> expect
   block/allow), including obfuscation cases; run in CI so guardrails cannot
   silently rot (gstack ratchet pattern).
5. **For determinism tooling**: mutation checks ARE the measurement (kill
   score reported in CI logs).

## 9. Source Index

| Topic | Key sources |
| --- | --- |
| Fresh-context review | arXiv:2603.12123 (CCR), arXiv:2605.08563 |
| Cross-model review | arXiv:2607.21656 |
| Judges/sycophancy | arXiv:2507.10535, arXiv:2502.08177, CriticGPT arXiv:2407.00215 |
| Test gaming | arXiv:2606.16062, arXiv:2605.12673 (BenchJack), RepoRescue |
| Mutation/PBT | vibe-mutation-test, arXiv:2602.08146 (AdverTest), Meta ACH arXiv:2501.12862 |
| Context rot | arXiv:2607.17937, morphllm.com/context-rot |
| Spec-driven | github/spec-kit, kiro.dev/docs/specs |
| Determinism | GGRS docs, xpTURN/Klotho, balaurengine.org, GDC 2024 Frontier slides |
