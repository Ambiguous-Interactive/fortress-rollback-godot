# Harness Tooling Facts

Verified operational facts about the `.llm/` enforcement tooling.
Evidence cites file:line at verification time; re-verify on touch.

| Fact | Evidence | Verified |
| --- | --- | --- |
| The meta-lint's link-integrity check validates only *relative* markdown links; `http(s)`, `mailto:`, and `#fragment` targets are skipped. | `scripts/llm/lint_llm_instructions.py:30-31` (skip prefixes), `:150-166` (relative-only resolution) | 2026-10-09 |
| Templates must keep placeholder paths in backticks: a markdown link to a nonexistent placeholder file fails link integrity. | `scripts/llm/lint_llm_instructions.py:145-166`; `.llm/templates/SKILL.template.md:36` does this correctly | 2026-10-09 |
| The 300-line scope covers every `.llm/**/*.md` except the generated skills index; generated agent stubs ARE in scope (8 lines each, so no practical risk). | `scripts/llm/llm_paths.py:28-29` (`GENERATED_RELATIVE`), `:50-78` (`size_scope_files`) | 2026-10-09 |
| Allowed skill categories are exactly `core`, `performance`, `feature`; frontmatter parsing accepts only single-line `key: value` scalars plus one nesting level under `metadata:`. | `scripts/llm/llm_paths.py:18`; `scripts/llm/llm_frontmatter.py:1-13` | 2026-10-09 |
| Harness self-tests bootstrap `sys.path` to `scripts/`, so they run as `python3 -m unittest discover -s scripts/tests -t scripts` and import via `from llm import ...`. | `scripts/tests/test_llm_repo_state.py:11-18` | 2026-10-09 |
| The index-freshness test requires every skill directory to have exactly one index row; rows are counted by the literal `\| [\`` marker, so an extra row fails CI. | `scripts/tests/test_llm_repo_state.py:65-72` | 2026-10-09 |
| Build GraphQL reviewThreads queries by generating the closing braces programmatically — seven `}` close the fully nested query while the `comments(first:1){nodes{databaseId body` fragment itself opens two — and enumerate PR/issue sets with the authenticated `gh` CLI — the OpenCode GitHub MCP `search_issues` ignored `offset`/`limit` and returned duplicated pages. | [Session 204](../../progress/session-204-feedback-sweep.md): measured command and output — the under-braced query fails with `Expected one of ... RCURLY (\"}\") at [1, 211]` from `gh api graphql`, and the working builder generates the tail as `'}' * 7`; `gh issue list --repo ... --json number --limit 100` enumerated all 56 open issues in one call while the MCP search returned the same issue three times per requested page. | 2026-11-19 |
