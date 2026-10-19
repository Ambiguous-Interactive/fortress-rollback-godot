# Retrospective: 2026-10-19 client input contracts

## Work under review

Replay Step/Pause validation, shared driver terminal preflight, reusable fixed-width input reads,
and independent finite spectator playback models. Runtime repairs and new APIs trigger this loop.
Evidence includes deterministic red/green controls, both native engine pins, explicit production mutations,
repeated input-read measurements and fresh adversarial reviews.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| Validating a departing frame leaves a corrupt paused destination unchecked | `test_replay_diagnostics.gd` stepped/paused cases reject the original viewer at boundary 8 | Route all pause actions through bounded boundary validation; extend owning browser testing guidance |
| A modeled bound can remain inactive throughout generated schedules | Fresh review found catch-up speed equaled capacity in all 72 schedules | Add threshold/backlog controls; production clamp-bypass fails exactly at ready=4, speed=3; extend oracle testing guidance |
| Wrapper avoidance and copy speed have different workload limits | Seven-sample input-read measurements improve one-byte samples but slow 256-byte samples | Preserve both APIs, adopt reusable scratch only for one-byte games, document width tradeoff and limit allocation claims |
| Terminal preflight must precede sample staging | `test_driver.gd` input_exhaustion fails on original frame/batch limits | Share the session limit check before submission, preserving unsupported recovery priority |

## Prune ledger

Updated existing browser/oracle references instead of creating overlapping skills or knowledge entries.
Existing paused-navigation guidance covered seek/cancel but left other pause actions implicit; it now names those actions.
Existing mutation guidance remains valid; the inactive-bound lesson adds a concrete sensitivity requirement.
No runtime contract or historical evidence was retired. Broader upstream/model/network acceptance remains in the linked issues.
The existing retrospective archive preserves older lessons; this artifact records only new evidence and its canonical actions.

## Outcome

Retro: findings-acted.
