# Retrospective: `2026-11-13 queue-capacity-oracle`

## Work Under Review

- Scope: `mesh_3_capacity9_late_flight` — the first non-power-of-two queue
  capacity in the P2P differential oracle (contract profile, both adapters,
  evidence/controls, unit tests, docs/PLAN/CHANGELOG), plus carried-forward
  devcontainer env-sync work and 113 engine sidecars. PR #356, 3+1 commits,
  ~1600 changed lines. Session log:
  `progress/session-176-queue-capacity-profile.md`.
- Trigger: large change (>300 lines), incident (working-tree data loss), new
  capability (capacity profile).
- Evidence base: scoped case receipts on Godot 4.3 and 4.7.2, the full 40-case
  local P2P corpus with 153 process controls, `make test-oracle` 25 p2p unit
  tests, `make lint-source` 507 files clean, fresh-context adversarial review
  (2 major, 6 minor findings, all acted).

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | Committing to `main` by accident and then running `git reset --hard origin/main` wiped every unstaged tracked edit; only untracked files survived. ~35 minutes of re-editing and re-verification followed. The ship-session skill already owned the principle ("do not discard them with a hard reset") but scoped it to the post-merge sync, not the branch-creation step where the hazard actually fired. | rule (existing, home extended) | `git reset --hard origin/main` mid-session; `git status` after showed only `??` entries; re-edit log in `progress/session-176-queue-capacity-profile.md` |
| 2 | An oracle that models a production bound must copy the production expression exactly — including truncation direction and the absence of clamps. The first draft "sensibly" clamped `max_input_delay` to zero; production has no clamp, so the comparable band admitted delay ops production refuses and the contract admitted profiles production cannot configure (capacity 8/prediction 4 has bound −1). A fresh adversarial reviewer caught both; engine probes confirmed GDScript truncation ((9,4) → 0). | rule (docs-owned) | `scripts/oracle/p2p_contract.py` `_trunc_div`; `tests/unit`-style pins in `scripts/oracle/test_p2p.py::test_queue_capacity_profile`; reviewer M1/M2 with `peer_session.gd:110,536` citations |
| 3 | Public peer scheduling cannot fill a receiver's queue: every producer's frontier is capped by its own prediction window over the shared confirmed frontier, so withholding traffic freezes the mesh in ~2 windows (measured peak span 3 rows vs a 9-row ring). Full-occupancy acceptance needs the access-only SyncLayer slice, as session 158's fallback anticipated. | fact (docs-owned) | `docs/oracle-p2p.md` "Non-power-of-two queue capacity"; #61 comment; calibration traces in `.cache/session176/` |
| 4 | Mid-run protocol time makes each implementation's input retry timer fire on its own bookkeeping — Godot retransmitted one operation before upstream during a long quiet stretch. The corpus's one-microsecond strides avoid the comparison; any future mid-run retry differential must first reconcile `last_send`/`last_progress` alignment. | fact (docs-owned) | first divergence at op 146 (actual `[120]` vs expected `[]` outgoing); `.cache/session176/p2p-capacity` traces; docs note + case comment in `scripts/oracle/p2p_capacity.py` |
| 5 | The local container had lost `libfontconfig1`; the system Godot printed a loader warning to stderr and `p2p_controls` failed its stderr-emptiness check. Environment drift, not repo drift: CI containers were unaffected. | fact | `apt-get install libfontconfig1` repaired it; `godot --headless --path . --script res://tests/oracle/p2p_game_controls.gd` stderr 122 bytes before, 0 after |
| 6 | Editing a tracked source during a receipted launcher run trips `require_unchanged` at the end — the guard worked exactly as designed (first full-corpus run passed all 40 cases, then failed its identity check because a docstring fix landed mid-run). | none (existing guard reinforced) | `.cache/session176/p2p-full-run.log` first run: `evidence identity changed: local source inventory; rerun` |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Extended the ship-session branch-creation step: create the session branch before the first commit and never hard-reset while unstaged work exists. | `.llm/skills/ship-session/SKILL.md` step 3 | `make lint-llm` |
| 2 | Recorded the container-drift fact (Godot stderr gate vs lost apt package) in the devcontainer knowledge store. | `.llm/knowledge/devcontainer-tooling.md` | `make lint-llm` |
| 3 | Bound-modeling rule recorded where oracle authors look: the case's docs section states "modeled exactly as production computes them (truncating integer division, no clamp)" and the unit test pins the negative-bound boundary. No second home created (would shadow docs). | `docs/oracle-p2p.md`; `scripts/oracle/test_p2p.py` | `python3 -m unittest test_p2p` 25/25 |
| 4 | Findings 3–6 live in their canonical homes (docs, case module, launcher guard) and this artifact; no duplication. | `docs/oracle-p2p.md`; `scripts/oracle/p2p_capacity.py` | full local corpus receipt |

## Prune Ledger

- Retired / merged / fixed at source: none — considered `.llm/knowledge/*`
  for findings 2–4 and rejected duplication; no store entry was invalidated.
- Verify-on-touch: reran `godot --headless ... p2p_game_controls.gd` (stderr
  empty) and the full p2p launcher against the repaired environment.

## Outcome

Retro: findings-acted. `make llm-index && make lint-llm && make test-llm` run
before publication of this file.
