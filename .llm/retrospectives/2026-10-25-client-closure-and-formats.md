# Retrospective: client closure and replay formats

## Work under review

Session 078 advances client driver diagnostics (#40), supported replay format
acceptance (#45), and clean spectator playback (#47). The trigger is the
reproduced clean-tail failure and expanded source acceptance.

## Findings and actions

| Finding | Evidence | Canonical action |
| --- | --- | --- |
| Input closure was mistaken for terminal playback; valid retries could abort a paused final tail. | `spectator_stream.gd` returned `TERMINATED` on `_is_finished`; the new stream/relay cases fail on the baseline and pass after repair. | Networking skill now requires trailing-retry tests after END through the relay. |
| Existing sequential differential playback exercised v5 only despite supporting v4. | New legacy acceptance case fails on the baseline; both pinned engines now compare 43 Rust cases with 172 Godot observations. | Oracle validation reference requires actual decoded version identity and current-bytes substitution controls. |
| Driver clients needed an expert reference to export existing canonical failure evidence. | New driver export case detects the absent API, then tests ownership, callback failure and replacement. | Driver facade and integration documentation expose the same bounded opt-in evidence. |

## Verification

Focused tests pass on Godot 4.3 and 4.7.2. Fresh adversarial reviews of
all three scopes found no actionable defects. Replay process controls reject
valid v5 bytes substituted into a v4 workload. Full native and native/Chromium
verification, final CI and delivery remain pending at this review. Their final
results belong in the session log and linked issue updates; focused evidence
does not establish release parity.

## Prune ledger

Searched existing networking and oracle guidance before adding lessons.
Extended their owning sections; no duplicate skill or knowledge entry was added.
No existing claim was superseded beyond the repaired implementation and updated
replay acceptance scope. Reviewed dependency pins remain unchanged; current
server documentation/public-upgrade checks do not prove complete compatibility.

## Outcome

Retro: findings-acted.

Original broad driver, replay and spectator acceptance remains in #40, #45 and
#47. Live spectator relay and startup model alignment remain #131 and #203.
