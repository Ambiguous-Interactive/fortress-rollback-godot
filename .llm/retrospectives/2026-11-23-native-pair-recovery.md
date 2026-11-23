# Retrospective for 2026-11-23

## Work under review

Integrate the upstream SignalFish direct-link replacement with the exported
native match. Keep startup loss, exhausted gameplay history and room departure
as distinct failure cases.

## Findings

| Finding | Evidence |
| --- | --- |
| Relay liveness can hide disabled direct restoration. | The exported control without the lobby opt-in continued confirming gameplay to frames 168–169 on relay. Neither affected page sent a replacement offer, and the recovery witness exited 1 in the physical close phase. |
| A route snapshot at either end of replacement can miss an unintended relay send. | The review control injects a relay recipient or sender on a healthy link while the current fallback set is empty. The before version reports `Missing expected exception`. The cumulative route check rejects both directions. |
| Each WebKit close needs its own pre-fault snapshot. | The same tagged reciprocal error proved `stream-close` against the original channel. Rechecking it against the already-closed record returned `null`. The controller now collects physical-close and departure evidence independently. |

## Actions and pruning

The [transport tooling note](../knowledge/transport-tooling.md) records the
route observation rule. The [native migration contract](../../docs/native-backend-migration.md)
now describes direct restoration through the pinned SDK and drops the stale
upstream dependency. The [browser control](../../scripts/reference/test_browser_cleanup.py)
checks transient relay use even when the healthy channel is direct again.

## Outcome

State `findings-acted`. Recovery qualification uses a closed original channel,
addressed relay input in both directions, and gameplay on a fresh reciprocal
connection. Scope is the existing native mesh room and accepted plan.
