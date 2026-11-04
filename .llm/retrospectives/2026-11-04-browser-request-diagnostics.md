# Retrospective: Browser request failure diagnostics

## Work under review

A post-merge spectator browser check rejected otherwise passing gameplay with only
`browser request failed`. Issue #322 tracks the missing request identity and the
separate investigation of the actual failure. This change adds diagnostics only.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A fatal request signal without request identity cannot distinguish the failed asset or phase. | The original observer discards the Playwright request argument. New real-Node tests fail on the original observer and pass after metadata capture. | Retain bounded sanitized metadata alongside the unchanged fatal error. |
| Diagnostic property access can throw independently of the original failure. | Node fixtures include throwing request proxies, invalid values and a throwing phase getter. | Capture the fatal error first; malformed metadata falls back or remains absent. |

The existing [browser integration guidance](../skills/testing/references/browser-integration.md)
now requires bounded request identity and preserves fatal failures when diagnostics fail.
No new skill duplicates that guidance. The earlier request-failure observer evidence
remains valid; no prior acceptance claims were changed.

## Verification

`python3 -m unittest discover -s scripts/reference -p 'test_spectator*py' -v`
covers the observer, actual Node runner processes and existing spectator validators.
The new controls inject startup, navigation, later state and final-drain failures,
including during final result construction. Teardown remains ignored.
URL credentials, query strings and fragments are removed; records and fields are bounded.

## Outcome

State: findings-acted. The actual post-merge request failure remains under investigation
in #322; successful diagnostic tests do not establish browser qualification.
