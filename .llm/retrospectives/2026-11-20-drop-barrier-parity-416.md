# Retrospective: 2026-11-20 drop-barrier parity port (#416)

Session 206 ported the pinned drop-barrier roster digest, closed-operation
journal and bounded retransmission record (#414, parents #48/#166) through a
green, reviewed, squash-merged session PR. The session's durable lessons:

## What happened

1. The wire gained a u64 `participants_digest` and the packet layout version
   moved to 3. PR-tier CI stayed green (the Reference Baseline's heavy legs
   skip on pull requests), but the merge queue's grouped candidate ran the
   full matrix and six SignalFish/Chromium WebRTC jobs failed: the browser
   harness fixtures baked the old version byte (`webrtc_instrument.test.cjs`)
   and the relay identity predicate's value-length arithmetic ignored the new
   trailing digest. Two queue-entry drops, two repair rounds.
2. The oracle roster fixture was verified against real emissions for the
   default one-slot scenario only. The re-review drove a two-target capture:
   the fixture roster is per-slot (`_id(slot / _slots)` repeats each
   survivor's identity per slot), so every two-target scenario rejected the
   real trailing digest until `fixture_roster_digest(target_slots)` made the
   contract slot-aware.
3. Bot and adversarial rounds converged on the same two design points from
   different angles (layout-version gate; roster validation on every phase),
   and one bot major (reconfigure doubling the roster) turned out to be
   refused by construction (`WRONG_STATE` on a second configure) — the fix
   was a contract pin, not production code.

## Durable lessons

- A wire-layout change is not landed until every byte-level consumer of the
  old layout is swept — including fixtures in other languages and the oracle
  `expected` builders that PR-tier CI does not execute. The merge queue runs
  them; a stale fixture drops the grouped candidate after the PR looked green.
- Derived per-roster values inherit the roster's granularity. When the
  roster is per-slot, digests differ per target-slot count, so every scenario
  shape (slot counts, warmup wraps) must be verified against real captured
  emissions, not just the default configuration.
- A scenario "refused by construction" still deserves its contract pinned by
  a test when a reviewer leans on it: the pin documents why no code change is
  needed and turns the declined finding into evidence.

## Numbers

- 7 commits, 1 session PR (#416), 3 issue updates (#414, #48, #166).
- Review surfaces: 2 OpenAI bot rounds (2 majors → 0 findings), CodeRabbit
  (CHANGES_REQUESTED → APPROVED), 2 adversarial sub-agent rounds (1 blocker +
  minors → verified fixes, 1 blocker + 2 minor/nit → fixed), 1 human-free
  authorization per the standing squash-merge grant.
- Merge queue: three enrollments (two dropped on full-matrix findings, the
  third landed); grouped candidate Gate + Qualification summary green.
