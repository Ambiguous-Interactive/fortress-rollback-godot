---
name: github-operations
description: "Use authenticated GitHub MCP for issues, PRs, reviews, checks and repository operations; use authenticated gh CLI for capability gaps. Applies to remote GitHub reads and writes, not local Git or pinned archive downloads."
metadata:
  category: core
---

# GitHub Operations

Use the authenticated GitHub MCP first for supported remote reads and writes.
Discover its available operations before choosing a fallback. Use authenticated
`gh` CLI when MCP lacks a required operation or cannot provide complete results.
This preference applies to issues, PRs, reviews, comments, checks, annotations,
workflow runs, repository metadata and merges. It does not expand authorization
for writes; follow the user's scope and [ship-session](../ship-session/SKILL.md).
Use Git for local history, fetch, push and worktree operations.

## Authenticated fallback

Validate each trusted credential candidate against the required GitHub endpoint.
Keep trying other available sources when a candidate is empty, expired or
rejected. A failed candidate does not prove that authenticated fallback is
unavailable. Use existing `gh` configuration, nonempty process environment
`GH_TOKEN`, `GITHUB_TOKEN` or `MCP_GITHUB_PAT`, a known trusted local credential
file, and the configured Git credential helper as available sources. Do not
search unrelated files for secrets.

When checking stored `gh` authentication, remove `GH_TOKEN` and `GITHUB_TOKEN`
from that subprocess environment, retaining their values privately for separate
candidate checks. Otherwise an expired environment token can mask valid stored
authentication. For a token candidate, set only that candidate as `GH_TOKEN`
and remove `GITHUB_TOKEN` in the client environment. Once a candidate passes,
keep that selected environment for subsequent CLI calls. Stored-authentication
mode keeps both overrides absent. Do not alter the caller's global environment.

Check the configured Git credential helper even when earlier sources exist but
fail validation. Request `protocol=https` and `host=github.com` through stdin to
noninteractive `git credential fill`. Set `GIT_TERMINAL_PROMPT=0` and
`GIT_ASKPASS=/bin/false`; capture all stdout/stderr inside the calling process.
Parse the password field there without displaying the helper response. Validate
that credential against the required GitHub endpoint with `GH_TOKEN` set only
inside the client process. If persistent CLI authentication is needed, provide
the validated token on stdin to
`gh auth login --hostname github.com --with-token`, with all output captured.
Do not use an interactive authentication mode.

Never print or echo tokens, dump credential files or environment variables,
interpolate secrets into shell commands, put them in command arguments, or write
them into session logs or repository files. Do not invoke interactive login or
credential prompts. Suppress credential-bearing diagnostics and report only
whether authentication succeeded and which operation remains unavailable.
Block authenticated fallback only after all available trusted sources fail
validation or are absent. Report that specific limitation and continue
independent work. Do not silently downgrade
to unauthenticated `gh`, direct HTTP or REST requests.

Use `gh api` for REST or GraphQL capability gaps, with authenticated pagination.
For multiline bodies, use structured MCP arguments or an owned temporary file
with `gh --body-file`; preserve actual newlines. Secret values stay in process
environment or existing `gh` configuration throughout the operation.

## Evidence and retry boundaries

Read every page and nested connection needed by the task. An MCP or CLI result
that is truncated, rate limited, unauthorized or incomplete cannot prove a
clean review or green CI. For feedback scans, read all four surfaces and thread
resolution state as required by [ship-session](../ship-session/SKILL.md).
Use authenticated `gh` for missing surfaces rather than treating an MCP gap as
absence of feedback. Authenticate the client used by repository backstop scripts.

After an uncertain write response, inspect authoritative remote state before
retrying. Preserve current-head and expected-head guards for checks and merges.
Keep provenance and completion evidence free of credentials. Authenticated
GitHub operations are separate from immutable, hash-verified public source
archive downloads used by the reference tooling.

For agent-authored GitHub text, follow [user-copy](../user-copy/SKILL.md).
