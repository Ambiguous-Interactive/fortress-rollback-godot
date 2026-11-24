# Native relay release dispatch

## Work under review

The eight-player Firefox relay witness now records controller release dispatch
and browser evaluation entry. [Issue #467](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/467)
tracks the delay before release. This change supplies timing evidence for that
investigation. The user also requested fewer GitHub API calls in later sessions.

## Findings and actions

| Finding | Evidence | Durable action |
| --- | --- | --- |
| Readiness and release start combine several waits. | [Hosted run 45336976309](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45336976309) recorded 8.58–8.98 seconds between those marks on Godot 4.3 before all eight peers reached the hold cap. | The [browser testing reference](../skills/testing/references/browser-integration.md) distinguishes controller dispatch, page entry and release start. |
| Dispatch can be recorded even when a browser call rejects. | The new assertions in the missing-history-response test failed with `undefined !== 11` on the old witness. With dispatch and page entry recorded, `python3 scripts/reference/test_browser_cleanup.py` reported `Ran 16 tests` and `OK`. | The [browser room guide](../../docs/experiments/upstream-binding.md#playable-web-rooms) explains which fields to compare on each clock. |
| Local Git resolves the baseline ref while a single hosted query inventories dependencies. | `git ls-remote origin refs/heads/main` returned the local main SHA. One authenticated GraphQL query returned the SDK, server and Fortress PR lists. | The [GitHub operations skill](../skills/github-operations/SKILL.md) records the user's preference to batch and reuse reads while preserving complete evidence. |

## Pruning and outcome

The [shipping skill](../skills/ship-session/SKILL.md) replaces the previous
unqualified run watcher example with a one-minute interval. The existing
release-start mark still measures the boundary after the snapshot.

State `findings-acted`. The hold cap and its timing on hosted runners remain
tracked in #467. Full native Firefox qualification remains tracked in
[#458](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/458).
