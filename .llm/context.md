# Fortress Rollback Godot — LLM Agent Instructions

You are working on **fortress-rollback-godot**: a GDScript-only port of
[fortress-rollback](https://github.com/wallstop/fortress-rollback), a
fortified, deterministic, GGPO-inspired rollback networking library (a fork of
`ggrs`). Target engine: **Godot 4.x**. Everything gameplay-relevant is written
in **GDScript 2.0**. The shipped addon has no Rust, GDExtension or C# dependency;
Rust is permitted for independent development oracles.
The project has pinned reference baselines, a deterministic test runner, bounded
queues/snapshots and a shared local rollback session engine. P2P transport and
browser release support remain planned. Treat this file as the canonical operating manual.

## Skills Index

All skills are listed in the generated index:
[./skills/index.md](./skills/index.md).

Skills follow the open [Agent Skills](https://agentskills.io) standard: each
lives at `.llm/skills/<name>/SKILL.md` with YAML frontmatter (`name`,
`description`, `metadata.category`). Only names + descriptions are visible
until a skill is activated, so keep bodies focused and link to
`.llm/code-samples/` and `.llm/research/` for depth.

## Repository Map

| Path | Purpose |
| --- | --- |
| `.llm/` | Canonical AI-agent harness (this folder). Source of truth. |
| `.llm/context.md` | This file. The one document every agent must read. |
| `.llm/skills/` | Agent Skills (SKILL.md standard), one directory per skill. |
| `.llm/skills/index.md` | GENERATED index. Never edit by hand. |
| `.llm/code-samples/` | Reviewed GDScript snippets referenced by skills. |
| `.llm/research/` | Data-backed research notes that justify harness/port decisions. |
| `.llm/knowledge/` | Distilled operational facts (gotchas/trivia) with evidence + verify dates — contract in [README](./knowledge/README.md). |
| `.llm/retrospectives/` | Post-work retrospective artifacts (the episodic record) — browse [artifacts](./retrospectives/). |
| `.llm/templates/` | Authoring templates (e.g. new skill skeleton). |
| `.claude/skills/` | GENERATED discovery stubs for Claude Code. |
| `.agents/skills/` | GENERATED discovery stubs (vendor-neutral). |
| `scripts/llm/` | Harness tooling (linters, generators). Python 3 stdlib only. |
| `scripts/tests/` | Self-tests for the harness tooling (unittest). |
| `.githooks/` | Dependency-free git hooks (see Automation). |
| `project.godot` | Godot 4.x project (fixed 60 Hz physics tick). |

## Critical Rules Summary

1. **Determinism is the product.** The sim must produce bit-identical state on
   every platform given identical inputs. Never use wall-clock time, global
   RNG, floats in transcendentals, threads, or the physics engine inside
   simulation code (see [determinism](./skills/determinism/SKILL.md)).
2. **Understand rollback before touching session code.** Save/restore of the
   full simulation state, input delay, prediction windows, and checksums are
   non-negotiable contracts (see
   [rollback-fundamentals](./skills/rollback-fundamentals/SKILL.md)).
3. **Every behavior change ships with a deterministic test** (see
   [testing](./skills/testing/SKILL.md)).
4. **Write typed, boring GDScript.** Static typing everywhere; autoloads only
   with strong justification (see
   [gdscript-style](./skills/gdscript-style/SKILL.md)).
5. **Transport details (channels, serialization, replays) go through the
   networking conventions** (see
   [networking-transport](./skills/networking-transport/SKILL.md)).
6. **Never exceed the file length caps, never hand-edit generated files, and
   keep every file LF/UTF-8 without BOM** (see
   [llm-harness](./skills/llm-harness/SKILL.md)).
7. **Close every large change with a retrospective.** Analyze the work
   with evidence, distill lessons into skills/knowledge/research, prune
   what became stale, and record the outcome — skip only with an
   explicit waiver (see
   [retrospective](./skills/retrospective/SKILL.md)).

## Session delivery and copy

Follow [ship-session](./skills/ship-session/SKILL.md) after every push and before
ending a session. Once the session PR has fully green current-head CI, scan all
four feedback surfaces with complete pagination and thread resolution state.
Address every actionable finding, recheck immediately before merge, squash merge
to `main`, and fetch/update local Git to match `origin/main`. This is standing
user authorization; no additional merge confirmation is needed.

Use [user-copy](./skills/user-copy/SKILL.md) for plain comments, PR titles and
bodies, commit messages and CHANGELOG entries. Set the maximum source line width
to **180 characters** in editors and formatters; `make lint-source` enforces it
across repository source files. File line-count caps remain separate.

## Commands

| Task | Command |
| --- | --- |
| Check source line widths | `make lint-source` |
| Validate the whole harness | `make lint-llm` |
| Run harness self-tests | `make test-llm` |
| Regenerate index + agent stubs | `make llm-index` |
| Install git hooks | `make hooks` |
| Check file lengths only | `python3 scripts/llm/check_llm_file_lengths.py` |
| Validate skills + pointers + links | `python3 scripts/llm/lint_llm_instructions.py` |
| Run the game/tests headless | `godot --headless --path .` |

## The .llm Harness (Architecture)

Single source of truth lives in `.llm/`. Every agent front-end reads a thin
pointer file that delegates here:

| Front-end | Pointer file |
| --- | --- |
| OpenCode, Codex CLI, Cursor, Aider, Jules, Devin, Zed, ... | `AGENTS.md` |
| Claude Code | `CLAUDE.md` |
| GitHub Copilot | `.github/copilot-instructions.md` |
| Gemini CLI | `AGENTS.md` |
| Cursor (scoped rules) | `.cursor/rules/llm-context.mdc` |
| Windsurf | `.windsurf/rules/llm-context.md` |
| Cline | `.clinerules/llm-context.md` |

Discovery stubs for the Agent Skills standard are **generated** into
`.claude/skills/<name>/SKILL.md` and `.agents/skills/<name>/SKILL.md`; each
stub points back at the canonical `.llm/skills/<name>/SKILL.md`. OpenCode
discovers skills natively through those same locations.

### File Length Contract (hard limits)

| Files | Limit | Over-limit behavior |
| --- | --- | --- |
| All `.llm/**/*.md` (except generated index) | 300 lines | error: split the file |
| Pointer files (`AGENTS.md`, `CLAUDE.md`, ...) | 50 lines | error: keep them thin |
| (advisory) any scoped file | > 270 lines | warning with `--verbose` |

A file at exactly 300 lines is "critical" (fails with `--fail-on-critical`).
Enforcement is layered: self-tests (`scripts/tests/`), the pre-commit hook,
and CI all run the same linters. When a context or skill outgrows its limit,
split content into `references/` beside the skill or a new skill.

### Generated Files — Never Hand-Edit

- `.llm/skills/index.md` (regenerated by `scripts/llm/generate_llm_index.py`)
- `.claude/skills/*/SKILL.md`, `.agents/skills/*/SKILL.md` (regenerated by
  `scripts/llm/generate_skill_stubs.py`)

Regenerate with `make llm-index`. CI regenerates and fails on any diff, so
drift cannot merge.

## Adding a Skill

1. Copy `.llm/templates/SKILL.template.md` to
   `.llm/skills/<your-name>/SKILL.md`.
2. `name` must equal the directory name: lowercase alphanumeric + single
   hyphens, max 64 chars.
3. `description` must be a single line (max 1024 chars) describing **what it
   does and when to use it**, with concrete trigger keywords.
4. Set `metadata.category` to `core`, `performance`, or `feature`.
5. Keep the body under 300 lines; move depth to `<skill>/references/` or
   `.llm/research/`, and samples to `.llm/code-samples/`.
6. Run `make llm-index && make lint-llm` — commit the regenerated files.

## Automation

- **Git hooks**: `make hooks` sets `core.hooksPath` to `.githooks/`; the
  pre-commit hook runs the length linter (staged files), index freshness,
  stub freshness, and the meta-lint.
- **pre-commit framework**: `.pre-commit-config.yaml` exposes the same checks
  as local hooks (`pre-commit run --all-files`).
- **CI**: `.github/workflows/llm-lint.yml` runs self-tests + every linter on
  any change touching `.llm/`, `.claude/`, `.agents/`, pointer files, or
  `scripts/`.
- **Makefile**: single entry point for all of the above.

## Encoding and Format Contract

Every file in harness scope must be UTF-8 **without BOM**, LF line endings,
with a single trailing newline. `.gitattributes` forces LF; the meta-lint
fails on violations. Markdown tables over bullet hierarchies; one H1 per file;
relative links only (they are integrity-checked).
