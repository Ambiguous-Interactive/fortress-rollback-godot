# Cache and scratch hygiene

This repository keeps three machine-local trees that survive every session:
the gitignored `.cache/` tree, scratch under the container's `/tmp`, and the
container's own package caches. Nothing used to remove them, so an unattended
agent could fill the disk without a single error message. On 2026-10-19 one
devcontainer held 634 GB of stale `/tmp` scratch and a 36 GB `.cache/`.

This page documents the tooling that keeps both bounded.

## Report

```sh
make disk        # how much the caches and scratch occupy
make prune       # what could be removed; deletes nothing
```

`make prune` prints every path it would remove, with the reason. It is a dry
run by default: deletion needs `make prune-apply`.

## Reclaim

```sh
make prune-apply
```

The pruner removes three kinds of thing:

| Scope | What it removes | Never removes |
| --- | --- | --- |
| `workspace` | session scratch, uncited run outputs and test receipts, and archives whose extraction already exists | a path named by a tracked file or a `progress/` note; the pinned toolchain under `.cache/reference/` |
| `scratch` | entries under `/tmp` older than the retention age | runtime directories (`arg0-linux`, `codex-daemon-*`, `claude-1000`, the X socket, `xvfb-run.*`) and anything a running process holds open |
| `container` | the npm content cache, the rust-docs component, superseded app-server releases | the newest app-server release |

Evidence is what a tracked file names. A citation of a cache *directory* --
the docs name `.cache/reference/results` as the place output goes -- is a
location reference, so it does not freeze the tree; only the specific files
a document names are protected.

Retention ages are configurable:

```sh
python3 scripts/prune_caches.py --scope scratch --scratch-ttl-hours 48
python3 scripts/prune_caches.py --scope workspace --session-ttl-days 3
```

## Scratch copies

Copying the working tree with a bare `shutil.copytree` also copies the
gitignored `.cache/` tree. In this repository that tree is tens of gigabytes,
so one such copy costs the same as the whole cache. Use the helper:

```sh
make scratch SCRATCH=probe-01          # copies the tree without .cache/.git/.godot
python3 scripts/scratch_workspace.py list
python3 scripts/scratch_workspace.py remove probe-01
```

`scripts/tests/test_prune_caches.py` fails the build if any repository script
copies the repository root.

## Build trees

The relay server's cargo output is about 970 MB. Building it into a per-run
output directory left one byte-identical copy per session. The builder now
uses one revision-keyed shared tree under `.cache/reference/server-target/`,
serialized by an exclusive lock because `cargo clean -p` removes artifacts
from the whole target directory. The executable is published as a copy at
`<output>/target/debug/signal-fish-server`, the path the probes and the docs
name, so a later rebuild cannot mutate bytes an existing receipt binds.

## Container lifecycle

`postStartCommand` runs `scripts/prune_caches.py` over the scratch and
container scopes on every container start. The repository's own `.cache/` is
only reported there, never deleted: cited evidence must survive.

`verify.sh` reports the cache and scratch sizes against budgets of 30 GB and
20 GB, and fails above them, so a regression is visible in the acceptance
harness instead of appearing later as a full disk. The pinned reference
toolchain alone is about 12 GB, so the budgets leave it room to grow.

## Related

- [workspace hygiene](../.llm/skills/workspace-hygiene/SKILL.md) -- the agent-facing procedure
- [cache hygiene facts](../.llm/knowledge/cache-hygiene.md) -- the measured evidence
- [reference baseline](./reference/README.md) -- what the pinned cache contains and why
