# Retrospective: 2026-10-25 history and playback

## Work Under Review

- Scope: donor publication fairness, retained replay checkpoint comparison and spectator startup acceptance lifetime.
- Trigger: three correctness repairs with new regression cases; fresh-context curator requested.
- Evidence: session 087 progress notes, current diff, native red/green JSON and regression assertions below.
- Machine-local JSON paths are evidence locations; tracked test links preserve the reusable reproduction.

## Findings and Actions

Bounded attempts can starve healthy links when service always starts at refused destinations.
`.cache/tests/drop-fairness-red.json` fails healthy destination assertions twice; its unpressured control passes.
`.cache/tests/drop-fairness-green.json` passes the healthy destination case twice.
The [regression](../../tests/unit/test_peer_drop_donor_fairness.gd), lines 55–85, exhausts the work budget with refused links.
Existing transport fairness guidance now requires rotation after attempted work while preserving per-link ordering.
Evidence proves initial publication under refusal, then convergence after pressure clears.
It does not establish retransmission progress under permanent refusal combined with packet loss.

Valid checkpoint restoration does not prove subsequent playback remains canonical.
`.cache/tests/replay-red.json` shows changed retained boundaries advancing instead of returning DESYNC.
`.cache/tests/replay-green.json` and `replay-green43.json` pass four cases twice per engine run, without runner errors.
The [regression](../../tests/unit/test_replay_expert_navigation.gd), lines 189–223, covers callback and expert APIs.
Rollback guidance now requires byte and checksum comparisons on retained boundaries during validation and advance.
Recordings without checksums still need these comparisons; cached evidence does not increase recorded-checksum coverage.

Returning authenticated acceptance can start remote publication after the local viewer stops.
`progress/spectator-accept-red.json` fails timeout, failure, completion and busy lifetime assertions.
`progress/spectator-stream-green.json` passes 17 cases twice per engine run.
The [regression](../../tests/unit/test_spectator_stream.gd), lines 698–735, checks outgoing acceptance and idle retry bytes.
Existing startup lifetime guidance now includes outgoing acceptance helpers and exact retries after requests finish.

## Prune Ledger

- Updated existing transport fairness and startup paragraphs in place; removed narrower single-blocked-peer and ingress-only examples.
- Extended the owning rollback skill instead of creating a competing replay skill or operational fact.
- Searched existing skills and knowledge first. No critical context invariant or tooling change was needed.
- No earlier claim was contradicted; the repaired examples replace incomplete coverage.
- Networking guidance remains 299 lines. Runtime, documentation and test changes belong to the task author.

## Verification and Outcome

- `make llm-index`, `make lint-llm` and `make test-llm` pass; 160 harness tests pass.
- Runtime evidence above was inspected; the curator did not rerun gameplay suites.
- Follow-ups: session author owns full native verification and delivery.
- State: `findings-acted`.
