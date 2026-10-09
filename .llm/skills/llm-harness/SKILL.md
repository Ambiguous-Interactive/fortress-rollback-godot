---
name: llm-harness
description: "How to maintain this repo's AI agent harness: .llm layout, 300-line caps, SKILL.md authoring, index/stub regeneration, pointer files, git hooks, CI. Use when editing .llm/, agent pointer files, or scripts/llm tooling."
metadata:
  category: core
---

# LLM Harness Maintenance

This repo's agentic harness: canonical context + skills in `.llm/`, thin
pointer files per vendor, generated Agent-Skills stubs, and linters enforced
by tests, git hooks, and CI. Inspired by the
[unity-helpers](https://github.com/wallstop/unity-helpers) harness, upgraded
to the [Agent Skills](https://agentskills.io) `SKILL.md` standard.

## Invariants (all enforced by tooling)

1. **Length caps**: 300 lines hard limit for scoped markdown (soft warning at
   270; "at limit" = critical); 50 lines for pointer files. Enforced by
   `scripts/llm/check_llm_file_lengths.py`.
2. **Generated files are never hand-edited**: `.llm/skills/index.md`,
   `.claude/skills/*/SKILL.md`, `.agents/skills/*/SKILL.md`. CI regenerates
   and fails on drift.
3. **Frontmatter contract**: `name` == directory name, lowercase + single
   hyphens; single-line `description` <= 1024 chars containing concrete
   trigger keywords; `metadata.category` in {core, performance, feature}.
4. **Encoding**: UTF-8, no BOM, LF-only, single trailing newline.
5. **Link integrity**: every relative markdown link inside `.llm/**` must
   resolve to a real file.
6. **Pointer delegation**: each pointer file must contain its exact
   delegation link (see `POINTER_FILES` in `scripts/llm/llm_paths.py`).

## Adding a Skill

```sh
cp .llm/templates/SKILL.template.md .llm/skills/<name>/SKILL.md
# edit frontmatter + body (<= 300 lines), then:
make llm-index && make lint-llm && make test-llm
```

Commit regenerated index + stubs together with the new skill.

## Editing `context.md`

- Exactly one H1; keep it under ~270 lines so it does not approach the cap.
- Rules stay one line each and link the owning skill — never duplicate skill
  content here (the skill is the depth; the context is the map).
- After edits: `make llm-index && make lint-llm`.

## Tooling Map

| Script | Role |
| --- | --- |
| `scripts/llm/llm_paths.py` | Single source of truth: paths, caps, pointer list, scope |
| `scripts/llm/check_llm_file_lengths.py` | Length ladder (error/critical/warning) |
| `scripts/llm/generate_llm_index.py` | Deterministic `index.md` generator (`--check`/`--write`) |
| `scripts/llm/generate_skill_stubs.py` | Agent stub generator (`--check`/`--write`/`--prune`) |
| `scripts/llm/lint_llm_instructions.py` | Meta-lint: pointers, context, frontmatter, encoding, links |
| `scripts/tests/` | unittest suite; includes full-repo integration tests |

## Workflows

- **Change .llm content**: edit -> `make llm-index` -> `make lint-llm` ->
  `make test-llm` -> commit everything.
- **Add a vendor pointer**: add the entry to `POINTER_FILES` in
  `llm_paths.py`, create the thin file, extend the research note
  (`.llm/research/agent-instruction-files-2026.md`) with the discovery-path
  evidence.
- **Change tooling**: update tests FIRST (red), then the script (green);
  CI runs the same suite.

## Design Rationale

Why 300 lines? Instruction files compete for attention; long files get
skimmed or truncated by front-ends. The cap is deliberately checked in three
layers (tests, hooks, CI) so a local misconfiguration cannot silently merge
oversized context. Why generated stubs? Vendors each demand their own
directory; stubs keep a single canonical body while satisfying every
discovery path. Evidence and the vendor matrix live in
`.llm/research/agent-instruction-files-2026.md`.
