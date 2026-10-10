# Retrospective: 2026-10-10 reference foundations

## Work under review

New capability: retained agent environment updates, pinned reference baseline,
source-family discovery, reviewed client contracts and evidence policy.
The [session record](../../progress/session-002-reference-foundations.md) owns
exact commands, CI links and remaining milestone gates.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Existence/version text checks hid failed processes. | New CLI controls failed on the retained helper for exit 42, with and without version output; fixed helper checks exit first. | Added error-path tests and infrastructure guidance to the testing skill. |
| Warm service state hid an asynchronous catalog startup race. | Fresh PR #54 image CI failed three discovery checks on both arches; isolated daemon first list empty, second list pending names. | Bounded actual CLI discovery polling, async regression, documented version-specific fact. |
| Parsing successful test lines without completion counts silently omitted an expected-panic case. | Strict reference parser found 8 executed sync tests versus the original 7 parsed; expected-panic suffix regression added. | Completed-stream controls and testing guidance. |
| A failed rerun retained a previous success report and timeouts retained old logs. | Fresh reference review reproduced stale reports; repair tests reproduced six red cases before changing the runners. | Invalidate success before setup, clear owned logs, preserve timeout output, add regression controls. |
| Human catalog glyphs excluded authentication states. | Automatic PR feedback and a red warning-glyph fixture reproduced missing server identities. | Query the same runtime API as structured JSON; status-independent identity tests and fresh review. |
| Malformed version bytes bypassed failure reporting. | Fresh runner review reproduced invalid UTF-8 leaving a prior passed receipt. | Invalidate before probes, safely decode diagnostics and add receipt regressions. |
| Source discovery and a status flag cannot establish semantic coverage. | Inventory verifies 632 files/337 families; release control rejects even forged coverage records. | Explicitly pending discovery schema, evidence limits and focused follow-up issue #55. |
| The documented image-cache refresh option was incorrect. | CLI 0.89.0 help exposes `--build-no-cache`; both README occurrences corrected. | Corrected docs and operational knowledge. |

## Curation and pruning

Searched existing knowledge, debugging and testing skills before writing.
Extended the testing skill at its existing test-evidence boundary; no new skill
or overlapping procedure was introduced. Added only version-specific environment
facts to the existing devcontainer topic. Replaced the overbroad download
“no rate limit” statement with the observed REST-quota avoidance claim.
Unsupported universal Codex standalone-install failure claims and the false
OpenCode v1-config-silently-ignored claim were removed at their source.
Generated instruction artifacts are regenerated and validated together.

## Outcome

State: `findings-acted`.
Remaining milestone work stays in the existing roadmap issues and the focused
coverage-certification issue. Source discovery is not called port coverage;
engine/codec smoke is not called rollback or SignalFish integration.
