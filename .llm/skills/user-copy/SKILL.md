---
name: user-copy
description: "Write plain comments, PR titles and descriptions, commit messages, and CHANGELOG entries. Use when authoring or reviewing these artifacts."
metadata:
  category: core
---

# User Copy

Adapted from `wallstop/unity-helpers` at commit `28d37d270c495f3e7416cf64a58db1e50212762b`:

- `.llm/references/context-agent-operations.md` — plain copy and PR format.
- `.llm/references/create-csharp-file-part-2.md` — minimal comments.
- `.llm/references/ship-changes-part-1.md` — commit hygiene.
- `.llm/references/ship-changes-part-2.md` — PR limits and Simplified Technical English.
- `.llm/references/update-documentation-part-1.md` and `update-documentation-part-2.md` — release notes.
- `.llm/skills/github-operations.md` — authorship disclosure.

Use the writing rules below for this GDScript repository. Follow higher-priority instructions and required repository templates when they require a different format.

Use [GitHub operations](../github-operations/SKILL.md) when publishing or reading
GitHub artifacts: authenticated MCP first, then authenticated `gh` for gaps.

## Plain Language

Use Simplified Technical English: common words, active voice, and one idea per sentence.
Aim for about 15 words per sentence; keep ordinary prose sentences at 25 words or fewer.
Keep API names exact. Remove filler and unexplained abbreviations.
Product action text must share its control's readiness gates; retained replay data does not imply a live match.
Explain why, how, and what in PRs and commit messages, with detail proportional to the change.
Keep technical mechanisms and investigation evidence in commit bodies or linked issues unless needed by a required review format.

## Comments

Aim for code that needs no explanatory comments. Improve names and structure first; spell names out rather than abbreviating.
Keep a non-doc comment only when it explains a non-obvious reason, invariant, or constraint. Delete comments that restate the code.
Use one short sentence for an ordinary comment. Remove commented-out code and decorative section dividers; link any TODO or FIXME to a tracked issue.
Keep necessary determinism and rollback explanations precise; a minimal-comment policy does not remove required contract documentation.
Use GDScript `#` for comments and `##` for public API documentation; C# block-comment and XML-doc syntax do not apply here.
Public API docs describe observable behavior, parameter and return contracts, failure cases, and important usage limits.
GitHub discussion and review comments use the same plain language and state the concrete finding or action briefly.

## PR Titles and Descriptions

Use an imperative title of 50 characters or fewer. Name the main effect the reader sees.
For tooling or guidance changes, name the effect on contributors. Put secondary changes in the body.
Count the title's characters before publishing it.

Use this sibling-repository format unless higher-priority instructions or a required repository template specify otherwise:

```markdown
DISCLOSURE: LLM-GENERATED TEXT

**Why:** <one sentence describing the problem>

**What:**

- <one change, at most 12 words>
- <another change, at most 12 words>

Fixes #123
```

Use two to five one-line What bullets, each at most 12 words. Use a real linked issue when one exists; omit the placeholder otherwise.
Rewrite the title and description around the final diff when scope changes.
Include before/after screenshots for UI changes when relevant.
Keep root-cause narratives, run IDs, session history, file lists, and routine validation reports out of the default PR body.
Put detailed evidence in the commit body or linked issue. Include validation or material risks when required by the active review instructions.

Begin every agent-written or materially edited GitHub body, review, comment, or reply with the exact disclosure above, followed by a blank line.
Preserve the disclosure when editing an existing body. Verbatim user-supplied text is not agent-written.
This authorship rule does not authorize posting comments, reviews, or messages beyond the user's instructions.

## Commit Messages

Use a short, imperative subject under 72 characters, such as `Fix rollback input prediction`.
Group related changes into a coherent commit that builds and passes its relevant checks.
When a body is useful, explain why first, then the behavior and approach in short, active sentences.
Put investigation details, measurements, and validation evidence here when they matter for review.
Avoid narrating abandoned work. Use the PR title and plain-copy rules for the final squash commit summary.

## CHANGELOG Entries

Add an entry for a user-visible feature, bug fix, or API change, including a production bug discovered through a test failure.
Internal CI, harness, build, developer-tooling, and test-only changes do not need release notes.
Update affected API docs and feature documentation with user-visible changes.
Add entries to `[Unreleased]`; released notes are immutable.

Keep each entry to one or two sentences and at most 300 rendered characters, excluding issue references and link targets.
Lead with the user-visible effect and any action the user must take.
Start with the verb named by the section: `Add` under Added, `Fix` under Fixed, and corresponding verbs for other sections.
A bold title is optional; when present, follow it with a colon: `- **Input delay**: Fix delayed inputs after reconnecting.`
Use the existing section order; for a new changelog, use Added, Fixed, Improved, Changed, Deprecated, Removed, Security.
Mark breaking changes explicitly and state the required migration.
Do not include root causes, internal mechanisms, run IDs, validation reports, or process detail.
Link longer explanations to a documentation guide. Check the rendered length before publishing; do not claim the sibling's npm linter exists here.

Related: [GDScript style](../gdscript-style/SKILL.md).
