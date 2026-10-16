# Retrospective: clean onboarding and retained diagnostics

## Work under review

Session 024 implements clean online onboarding, owned work statistics, private
report downloads and bounded retries for native CLI publication. The work adds
public diagnostics and repairs container installation failures. Evidence is in
[the session log](../../progress/session-024-onboarding-and-diagnostics.md).

## Findings

| Finding | Evidence | Type |
| --- | --- | --- |
| An event field name does not guarantee a scalar value or safe export. | `handshake_agreement.gd` returns nested roster/neutral-input values in `reason`; the fresh reviewer reproduced leaked values and mutable aliases. | Procedure |
| Event draining must not determine when a terminal diagnostic becomes available. | The actual incompatible-handshake witness had a terminated core and empty diagnostic until a second collection. The public mismatch test now checks before and after drains. | Invariant |
| Native publication can fail during metadata lookup or installation; exact package/version boundaries matter. | The old install fails controlled ETARGET; the first repair accepted fourteen unrelated version suffix cases. Complete-token regressions now pass. | Operational fact |
| Slow diagnostic downloads can change the live scenario being observed. | Final-head CI froze correctly at frame 289, beyond the witness's 256-frame history domain, after serial downloads advanced live frames 175→207 and 217→257. | Procedure |
| A clean-project fixture can share the actual documented install and host commands. | Both pins execute the same installer, missing-SDK flow, production export and HTTPS/WSS host before canonical browser gameplay. | Procedure |

## Actions taken

| Action | Home | Verification |
| --- | --- | --- |
| Require type-aware export normalization and terminal-time capture. | [Networking skill](../skills/networking-transport/SKILL.md) | Public FPS/roster/neutral-input mismatches and terminal pressure tests. |
| Record exact native readiness/alias and version-token behavior. | [Container knowledge](../knowledge/devcontainer-tooling.md) | Seven installer cases, real isolated installs and CI container builds. |
| Move browser report downloads after physical teardown and require offline, unchanged frame/restore observations. | [Networking skill](../skills/networking-transport/SKILL.md) and browser fixture | CI artifact and offline/frozen export controls. |
| Replace incomplete online setup with the commands the fixture executes. | [Online guide](../../docs/online-example.md) | Fresh-user-directory native checks, production export and both-pin browser runs. |

## Prune ledger

The container guide's stale pin-on-failure advice is replaced by the verified
latest-preserving publication policy. The online guide's assumed repository setup
is replaced at source with explicit clean-project commands. Existing transport
knowledge about secure contexts and WSS remains valid and is not duplicated.
No skill is added; the existing networking skill owns event/privacy contracts.

## Outcome

State: findings-acted.

The diagnostic report is an observation snapshot. Issue #42 retains canonical
state/input trace and replay artifacts. Issues #38/#39/#75 retain advanced
transport, public-network and full release matrix gates.
