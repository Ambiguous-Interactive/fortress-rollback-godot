# Retrospective: 2026-10-19 cache and scratch hygiene

## Work under review

- Scope: disk exhaustion in the devcontainer (634 GB of stale `/tmp` scratch,
  a 36 GB `.cache/` tree, 1.9 GB of container-layer caches) and the durable
  fix for it: `scripts/prune_caches.py`, `scripts/scratch_workspace.py`, a
  shared revision-keyed cargo target tree, a post-start hook, a disk budget
  in the acceptance harness, a new skill, and a knowledge store.
- Trigger: incident (the disk filled; nothing reported it) plus a hardening
  change to the reference build.
- Evidence base: measured disk usage before and after, the pruner's own
  dry-run report, 128 harness self-tests, 109 reference tests, a real
  relay-server build whose receipt validates against the pinned source.

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | A bare `shutil.copytree` of the repository root also copies the gitignored `.cache/` tree. Nineteen such copies held 627 GB in one container. | fact | `du -sh /tmp/claude-1000/rr/*` reported 33G for each of nineteen directories; the copy came from `/tmp/claude-1000/rr/mut.py` |
| 2 | The container's `/tmp` is not session-scoped and nothing removed it, so scratch accumulated for nine days unnoticed. | fact | `du -sh /tmp` reported 634G before the cleanup and 0.23G after |
| 3 | A per-run cargo target directory is a gigabyte-scale leak: the relay server's build tree is 970 MB and was copied once per session (20 copies, 21 GB). | fact | `du -sm` on twelve `*/signalfish-server-build/target` trees reported 970M each; the published binary alone is 52 MB |
| 4 | `cargo clean -p <package>` clears the whole target directory, so a shared tree is only safe under an exclusive lock. | fact | `scripts/reference/signalfish_build_server.py` runs `clean -p signal-fish-server` before every build; the shared tree is guarded by `fcntl.flock` |
| 5 | A published executable must be a copy, never a hard link into a shared tree: a later rebuild would mutate the bytes an existing receipt binds. | rule | The receipt records `binary_sha256` and `signalfish_live_probe.py:128` re-checks it; the publisher uses `shutil.copy2` |
| 6 | The CI workflow already declared the cargo output to be non-evidence, so the old layout was wrong by the repo's own standard, not merely wasteful. | fact | `.github/workflows/reference-baseline.yml:274-277` excludes `signalfish-server-build/target/` from the uploaded artifact |
| 7 | A citation of a cache *directory* is a location reference; treating it as a freeze makes the cache unprunable. | technique | `docs/reference/README.md:34` names the directory, `.llm/retrospectives/2026-10-18-spectator-streams.md:29` names a file |
| 8 | Ignore rules are not citations: `/.cache/session-*/` in `.gitignore` protected every session directory until it was excluded from the citation scan. | fact | The first pruner draft reported "session-013 protected" with no evidence behind it; excluding `.gitignore` released 13.2 GB |
| 9 | Nothing in the acceptance harness looked at disk usage, so a regression could only be discovered by running out of space. The budgets must be set against the legitimate footprint, not against zero: the pinned reference toolchain alone is about 12 GB. | harness | `verify.sh` now reports cache and scratch sizes against 30 GB and 20 GB budgets |
| 10 | The pruner's protection check compared every candidate against every citation, so the first full report spent 96 of its 99 seconds on `Path.is_relative_to`. A citation protects a path and its ancestors; expanding the citations once turns the check into a set lookup. | technique | `cProfile` on `plan_workspace` attributed 98.4 s of 99.0 s to `is_protected`; after the expansion the same plan takes 1.1 s and reports the identical 2388 entries |

## Actions taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Pruning tool with a citation-derived allowlist, age-based retention, redundant-archive detection and a dry-run default | `scripts/prune_caches.py` | `scripts/tests/test_prune_caches.py` (17 tests) |
| 2 | Scratch-copy helper that skips `.cache/`, `.git`, `.godot` and `progress/` | `scripts/scratch_workspace.py` | `scripts/tests/test_prune_caches.py` |
| 3 | Guardrail that fails the build when a script copies the repository root or a cache tree appears inside the source tree | `scripts/tests/test_prune_caches.py` | `python3 -m unittest discover -s scripts/tests -t scripts` |
| 4 | Shared revision-keyed cargo target tree with an exclusive lock and a copied published binary | `scripts/reference/signalfish_build_server.py` | `scripts/reference/test_server_build_target.py`; a real build whose receipt validates |
| 5 | `make prune`, `make prune-apply`, `make disk`, `make scratch` | `Makefile` | `make prune` (dry run) |
| 6 | Post-start hook that prunes scratch and container caches on every container start | `.devcontainer/post-start.sh`, `devcontainer.json` | `bash -n`; `--scope scratch --scope container` run |
| 7 | Disk budget in the acceptance harness | `.devcontainer/verify-tools.sh`, `verify.sh` | `check_disk_budget` run in isolation |
| 8 | Agent-facing procedure | `.llm/skills/workspace-hygiene/SKILL.md` | `make lint-llm` |
| 9 | Distilled facts with measurements | `.llm/knowledge/cache-hygiene.md` | `make lint-llm` |
| 10 | Human-facing guide | `docs/cache-hygiene.md` | `make lint-source` |
| 11 | Protection check expanded once into a set, so a full report takes seconds instead of a minute and a half | `scripts/prune_caches.py` (`protection_set`) | `scripts/tests/test_prune_caches.py` (`ProtectionSetTest`); identical 2388-entry plan before and after |

## Prune ledger

- Retired / merged / fixed at source: the per-run cargo target directory was
  fixed at source rather than documented as a known cost. The `.gitignore`
  pattern `/.cache/session-*/` is no longer read as an evidence citation.
- Verify-on-touch: the relay-server receipt was re-validated against the
  pinned source, toolchain, binary digest and build log after the change to
  the shared target tree.

## Outcome

- State: `findings-acted`
- Follow-ups: the reference baseline's own `.cache/reference/target` tree
  still holds 1.4 GB of incremental compilation state; pruning it costs a
  full oracle rebuild and was left alone deliberately.
