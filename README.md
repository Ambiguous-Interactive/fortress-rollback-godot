# Fortress Rollback Godot

A **GDScript-only port** of [fortress-rollback](https://github.com/wallstop/fortress-rollback)
— a fortified, deterministic, GGPO-inspired rollback networking library — targeting
**Godot 4.x**.

> [!WARNING]
> This project is in an early bootstrap phase. The rollback engine itself is not
> implemented yet; this repository currently ships the project skeleton and its
> AI-assisted development harness.

## AI-Assisted Development Notice

This repository is developed with heavy AI-assistance and carries a generic
**agentic harness** (inspired by
[unity-helpers](https://github.com/wallstop/unity-helpers)):

- Every agent front-end (Claude Code, Codex, Copilot, OpenCode, Cursor,
  Gemini CLI, Windsurf, Cline, ...) reads a **thin pointer file** that
  delegates to a single canonical context document.
- The canonical context and all skills live under [`.llm/`](./.llm/context.md).
- Skills follow the open [Agent Skills](https://agentskills.io) `SKILL.md`
  standard, with generated discovery stubs under `.claude/skills/` and
  `.agents/skills/`.
- Every file in the harness is capped at **300 lines** (hard limit), enforced
  by tests, git hooks, and CI.

See [`.llm/context.md`](./.llm/context.md) for the full operating manual.

## Quick Start

```sh
# Install git hooks (blocks commits that break the harness)
make hooks

# Validate the entire .llm harness
make lint-llm

# Run the harness self-tests
make test-llm

# Regenerate the skills index + agent discovery stubs
make llm-index
```

## License

[MIT](./LICENSE)
