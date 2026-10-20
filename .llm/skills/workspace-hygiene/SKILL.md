---
name: workspace-hygiene
description: "How to keep this repo's machine-local caches, scratch directories, and build outputs from filling the disk. Use when creating scratch copies of the working tree, writing temporary artifacts, building the Rust oracles, noticing the container running low on disk, or deciding what may be deleted from .cache/ and /tmp."
metadata:
  category: core
---

# Workspace Hygiene

This repo's devcontainer accumulates machine-local growth that nothing used
to remove: the gitignored `.cache/` tree, scratch under the container's
`/tmp`, and per-session copies of the working tree. Measured on 2026-10-19:
634 GB of stale `/tmp` scratch and a 36 GB `.cache/` in one container, both
surviving every session.

Facts and evidence: [cache hygiene](../../knowledge/cache-hygiene.md).

## The Rule

**Never copy the whole working tree, and never let a build tree land in a
per-run output directory.** Both cost a gigabyte-scale multiple per session.

1. Scratch copies use `make scratch SCRATCH=<name>` (or
   `python3 scripts/scratch_workspace.py create <name>`), which skips
   `.cache/`, `.git`, `.godot`, and `progress/`.
2. Temporary artifacts go under `.cache/scratch/<name>/`, never in `/tmp`
   and never beside the sources.
3. Report growth with `make prune` (dry run) and remove it with
   `make prune-apply`.
4. Evidence is what a tracked file names. `make prune` never removes a
   cited path; it removes everything else once it is older than the
   retention age.

## Why

`shutil.copytree` of the repository root also copies the gitignored
`.cache/` tree. In one session, nineteen such copies wrote 627 GB to
`/tmp` before a single byte was deleted. The relay server's cargo output
is about 970 MB, so a per-run build directory left a byte-identical copy
behind on every session -- twenty copies, 21 GB.

Both are silent: nothing errors, nothing prints, and the disk fills over
days. A build that lands in a shared, revision-keyed tree keeps one copy
instead of one per session; a scratch copy that skips `.cache/` is
megabytes instead of gigabytes.

## How

| Situation | Do this |
| --- | --- |
| Need an isolated copy of the tree | `make scratch SCRATCH=probe-01` |
| Need a temp directory | `python3 scripts/scratch_workspace.py create probe-01` and use `.cache/scratch/probe-01/` |
| Cache or scratch looks large | `make disk` for the sizes, `make prune` for what is removable |
| Ready to reclaim | `make prune-apply` |
| Starting a session | `make prune` (report only), then act on the report |
| Building the Rust oracles | use `scripts/reference/signalfish_build_server.py`; its target tree is shared and revision-keyed, so do not add a per-run `CARGO_TARGET_DIR` |
| Adding a script that copies files | copy a subtree, never the repository root; `scripts/tests/test_prune_caches.py` fails the build if you do |

## Checklist

- [ ] No new copy of the working tree includes `.cache/`, `.git/`, or `.godot/`
- [ ] No new build writes its target tree into a per-run output directory
- [ ] Temporary output lives under `.cache/scratch/`, not in `/tmp`
- [ ] `make prune` reports no unexplained growth before the session ends
- [ ] Every artifact worth keeping is named by a tracked file

## Related

- Related skill reference: `testing` at path `../testing/SKILL.md`
- Related skill reference: `llm-harness` at path `../llm-harness/SKILL.md`
