# Research: Agent Instruction Files & Skill Standards (2026)

Evidence base for this repo's harness design. Compiled 2026-10 from
first-party docs (agentskills.io, opencode.ai/docs/skills) and current
vendor documentation. Update this file whenever a design decision changes;
cite sources inline.

## The SKILL.md Standard (agentskills.io)

A skill is a directory containing `SKILL.md` with YAML frontmatter:

| Field | Required | Constraint |
| --- | --- | --- |
| `name` | yes | 1-64 chars, `[a-z0-9-]`, no leading/trailing/double hyphens, **must equal the directory name** |
| `description` | yes | 1-1024 chars; should say what + when, with trigger keywords |
| `license`, `compatibility`, `metadata`, `allowed-tools` | no | metadata is a string->string map |

Progressive disclosure: metadata (~100 tokens) loads at startup; body loads
on activation (recommended < 5000 tokens, file < 500 lines); `scripts/`,
`references/`, `assets/` load on demand. This validates the unity-helpers
"router" pattern and our generated-stub approach.

## Vendor Discovery Matrix (what reads what, 2026)

| Front-end | Instruction file(s) | Skills |
| --- | --- | --- |
| OpenAI Codex | `AGENTS.md` (primary) | `.agents/skills/` |
| Claude Code | `CLAUDE.md` (does **not** read AGENTS.md natively as of 2026-08) | `.claude/skills/` |
| GitHub Copilot | `.github/copilot-instructions.md`; also reads `AGENTS.md` (nearest file wins) | yes |
| Cursor | `AGENTS.md`; `.cursorrules` is legacy/deprecated; `.cursor/rules/*.mdc` for scoped rules | yes |
| Gemini CLI | `AGENTS.md` (also `GEMINI.md`) | no |
| Windsurf | `AGENTS.md`; legacy `.windsurfrules` / `.windsurf/rules/` | no |
| OpenCode | `AGENTS.md`; skills discovered in `.opencode/skills/`, `.claude/skills/`, `.agents/skills/` | yes |
| Cline | `.clinerules/`; `AGENTS.md` | no |
| Devin / Jules / Aider / Zed / Amp | `AGENTS.md` | varies |

## Decisions (ADR-style)

1. **Canonical context = `.llm/context.md`** (from unity-helpers): one file
   holds the real instructions; front-end files are thin pointers with an
   exact, lint-enforced delegation link. Avoids 7-way content drift.
2. **Canonical skills = `.llm/skills/<name>/SKILL.md`** in real Agent Skills
   format rather than unity-helpers' flat `.md` + HTML-comment triggers:
   the YAML frontmatter *is* the trigger metadata, natively understood by
   Claude Code, Codex, Copilot, Cursor, and OpenCode.
3. **Generated stubs in `.claude/skills/` + `.agents/skills/`**: covers
   Claude Code (which needs `.claude/`) and Codex (which needs `.agents/`).
   OpenCode reads both and dedupes by name; unity-helpers ships the same
   dual-stub layout in production. Stubs are 8-line pointers, so an agent
   that activates one is immediately redirected to canonical content.
4. **`AGENTS.md` for everyone else** (Cursor, Gemini, Windsurf, Cline,
   Devin, ...): the Linux-Foundation-stewarded standard has the widest
   reach; `.cursorrules` is deliberately NOT created (deprecated upstream).
5. **300-line hard cap** (repo owner's spec; unity-helpers tightened theirs
   to 199/180): enforced as error > 300, critical == 300, warning > 270.
   Pointer files capped at 50 lines to keep wrappers thin.
6. **Deterministic generated files + freshness checks in CI** (from
   unity-helpers): index and stubs are byte-deterministic (ordinal sort, LF,
   UTF-8 no BOM, no timestamps); `--check` modes make drift a CI failure.
   Cross-OS determinism is additionally protected by `.gitattributes`
   forcing LF for all text.
7. **Python 3 stdlib tooling**: gdtoolkit (gdformat/gdlint) already makes
   Python the de facto companion runtime for Godot projects; zero-dependency
   scripts keep the harness runnable anywhere, and `unittest` covers the
   linters themselves (tests enforce the enforcers).
8. **Hook layering**: dependency-free `.githooks/pre-commit` (via
   `core.hooksPath`) AND `.pre-commit-config.yaml` for teams that prefer the
   pre-commit framework; CI is the final authority either way.
9. **GEMINI.md dropped (2026-10)**: Gemini CLI reads `AGENTS.md` natively,
   so a dedicated pointer file was redundant surface; removed from
   `POINTER_FILES` and CI triggers.

## Open Questions / Future Work

- Watch Claude Code's stance on native `AGENTS.md` reads
  (anthropics/claude-code#50778); if it lands, `CLAUDE.md` could be dropped.
- If Copilot's glob-scoped `.github/instructions/*.instructions.md` becomes
  useful (per-filetype rules), add them as pointer files with their own
  `POINTER_FILES` entries.
- Consider `skills-ref validate` (agentskills reference validator) in CI as
  a second opinion once skills grow beyond ~20.
