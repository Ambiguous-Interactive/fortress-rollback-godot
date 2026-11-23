# Retrospective for 2026-11-23

## Work Under Review

Drift artifact publication and native eight-player browser evidence. The hosted drift rerun removed the first upload, and existing browser receipts exposed two gaps in the evidence collector.

## Findings

| Finding | Evidence |
| --- | --- |
| Distinct attempt names did not preserve a previous artifact. | Drift Report run 45241137594 uploaded 14849409877 and 14851980841. After the rerun, a direct request for 14849409877 returned HTTP 404. The second ZIP matched the Actions API SHA-256. |
| Exact observation text can appear inside HTML comments or fences. Unicode separators can also pass Python's splitlines while leaving the Markdown command unfenced. | Three reporter controls failed before the canonical-header and literal line-break checks. The corrected reporter suite passed all 35 tests. |
| Arrival and matching measure different things in a busy relay. | The hosted Firefox 4.3 failure had replies on every direction. The latest wire report was 13.432–15.844 seconds ahead of the source's latest echoed token across 56 ordered links. Keeping 16 tokens covered about 3.2 seconds. |
| Clock uncertainty can dominate a teardown result. | Replaying the captured WebKit failure preserved all 45 exact-abort proofs. Intersecting four post-departure reads proved 11 of the other 13 tags. The last two still lacked the required margin. |

## Actions Taken

- The [GitHub operations skill](../skills/github-operations/SKILL.md) records the raw archive SHA-256 check, rerun retention and comment edit boundaries.
- The [ship-session skill](../skills/ship-session/SKILL.md) queries `autoMergeRequest.enabledAt`. Live GraphQL type introspection listed `enabledAt` and omitted `state`.
- The relay probe keeps the newest 256 tokens per remote and records each event direction independently. The delayed-reply test went from one matched trip to two.
- The WebKit probe intersects existing clock windows and preserves the five-second deadline and 2 ms margin. The local Godot 4.7.2 run matched 40 rows and proved 22 exact sends.

## Prune Ledger

Removed the stale merge queue field and superseded the standalone replay-text check with canonical Markdown validation. The GitHub issue-comment endpoint exposes an unconditional update. The reporter serializes hosted writers and re-reads the bot comment immediately before the update. Existing human prefixes outside the managed header leave the comment untouched.

## Outcome

State `findings-acted`. Browser issues #458, #459 and #460 retain their hosted acceptance. Physical Safari qualification remains on #457.
