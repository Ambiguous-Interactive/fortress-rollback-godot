# Retrospective: 2026-10-18 npm global packages not user-updatable

## Work Under Review

- Scope: root-cause analysis and durable repair of `npm install -g` / `update -g` /
  `uninstall -g` failing with `EACCES` for every agentic CLI in the devcontainer.
  Diff: `.devcontainer/npm-global-perms.sh` (new, 96 lines), `Dockerfile` (+13),
  `verify-tools.sh` (+80), `verify.sh` (+3), `README.md` (+55),
  `.llm/knowledge/devcontainer-tooling.md` (+7 facts).
- Trigger: incident (debugging session), external knowledge (npm CLI docs), harness
  change (new acceptance check), corrections (four self-inflicted wrong turns below).
- Evidence base: reproduced EACCES three ways as `vscode`; single-variable control
  experiment; `npm doctor` output; `which@3.0.1` sudo experiment; full
  `.devcontainer/verify.sh` at 29 passed / 0 failed; `make lint-source`;
  `make lint-llm`; `shellcheck -S style`.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The Dockerfile installs every agentic CLI from npm's global prefix as root, then `remoteUser: vscode` runs the container. On Unix the global write path needs write permission on the *parent* directory, so the failure is total for writes (mkdir for new, rename for update/remove) while `npm ls -g` and `npm view` still succeed and hide it. | fact | `EACCES ... rename /usr/local/lib/node_modules/@openai/codex` (user report, reproduced); `npm i -g is-number` → `EACCES ... mkdir`; `npm un -g` → `EACCES ... rename` |
| 2 | `npm doctor` is a false oracle here: it exited 1 while reporting all five permission checks `Ok`, because it flags group/world-writable directories and never tests writability by the current user. | fact | `npm doctor` output: only `Not ok / Use npm v12.2.0` and `Not ok / Use node v24.22.0` were failing — both intentional pins. |
| 3 | npm's own guidance is to avoid global installs as a non-root user by using a Node version manager (nvm). Rejected: nvm makes global binaries depend on a shell-initialised PATH, which breaks MCP servers spawned without a login shell (`.mcp.json` invokes `godot-mcp` directly) and conflicts with the repo's pinned-infrastructure design goal. Group write on the existing prefix achieves the same outcome with zero PATH, layout or duplication change. | research | npm/cli `configuring-npm/install.md` (context7 `/npm/cli`): "We strongly recommend using a Node version manager"; blast radius assessed against `.devcontainer/verify.sh` MCP checks |
| 4 | Regression instruments must be validated with a single-variable control before being trusted. Two of my own instrument bugs produced convincing but wrong signals. | technique | (a) control pass on a user-writable prefix failed on "residue" because `npm un -g` leaves an empty scope dir; (b) the harness probe hardcoded `frg-probe-1.0.0.tgz` and so failed as "tarball seems to be corrupted" — a red that did not test permissions at all |
| 5 | Guard tests can be destructive. Passing `root` to the repair script silently re-chgrp'd the whole global root to `root:root` and reported success, because `runuser -u root -- test -w` always passes. Found only by re-checking state afterwards. | harness | after `sudo npm-global-perms.sh root`: `root:root 2775`, `vscode` write test = NO; fixed by refusing a `root` target group |
| 6 | setgid alone does not keep the fix self-healing: root-created packages get the right group but no group write, so `npm un -g` fails `ENOTEMPTY` and leaves `.pkg-XXXX` residue. | fact | `sudo npm i -g which@3.0.1` → `drwxr-sr-x 0:1000`; `npm un -g which` → `ENOTEMPTY ... rename`, exit 217, both dirs remained |
| 7 | `verify.sh`'s git-hooks check is over-strict: it string-compares `core.hooksPath` to `.githooks`, so an absolute path fails although git honours it. Pre-existing failure at pristine HEAD, unrelated to this work. | harness | pristine `HEAD`: hooksPath `/workspaces/.../.githooks` → FAIL; `make hooks` → `.githooks` → PASS |
| 8 | Devcontainer features build *after* the user Dockerfile, so a Dockerfile step that repairs filesystem state cannot cover a package a feature installs as root. This made the first version of this fix broken on every rebuild while its own guard reported green. | fact | `Dockerfile:24-26` "Installed before features run (the claude-code feature detects and reuses it)"; Dockerfile never installs `@anthropic-ai/claude-code`; simulated feature install after the repair → `root:vscode 2755` → `EACCES ... unlink` |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Recorded 8 operational npm-permission facts with reproduction evidence | `../knowledge/devcontainer-tooling.md` (new "npm global packages" table) | `make lint-llm` |
| 2 | Re-applied the repair after devcontainer features, which build after the Dockerfile and reinstall a global package as root | `.devcontainer/post-create.sh`, Dockerfile comment | simulated post-feature prefix: `root:vscode 2755` → repair → `2775`, then `npm i -g` succeeded |
| 3 | Made the acceptance check prove the precondition and the replace path, and refuse to run as root | `.devcontainer/verify-tools.sh` `check_npm_global_writable` | red in the post-feature state, red on a broken prefix, red as root, green after repair |
| 4 | Narrowed the `bin` half of the repair to the directory, used `g+rwX`, applied setgid through `xargs` and asserted it | `.devcontainer/npm-global-perms.sh` | `shellcheck -S style`, `bash -n`, guards, idempotency |
| 5 | Corrected every documentation claim the review disproved, including the "last build step" and `ENOTEMPTY` statements | `.devcontainer/README.md` | `bash .devcontainer/post-create.sh` end to end |

## Prune Ledger

- Retired / merged / fixed at source: no stale entries found. The existing
  "Native CLI publication" npm facts are about install-time resolution, not
  filesystem permissions, so they stay separate rather than merged.
- Verify-on-touch: re-ran the stored evidence for every new fact. The six new rows
  were each reproduced in this session; `npm doctor`, the EACCES trio and the
  `which@3.0.1` residue experiment were all re-executed rather than recalled.
- Left standing deliberately: `npm` remains at the image-pinned 10.9.9 while
  `npm doctor` recommends 12.2.0. That is the documented version policy, not rot.

## Review

A fresh-context adversarial review (given the diff and the problem statement, explicitly barred from reading this retrospective or the knowledge store) returned **DO-NOT-SHIP** with one blocker and two majors. All were reproduced before acting.

- **BLOCKER — the repair was undone on every rebuild.** Devcontainer features are appended as layers after the Dockerfile, and the claude-code feature installs a global npm package as root. The Dockerfile repair therefore never covered `@anthropic-ai/claude-code`, and the README's headline in-place update command would still fail with the original `EACCES` in any fresh image. Fixed by re-applying from `post-create.sh`, which runs after features.
- **MAJOR — the regression guard false-passed in exactly that state.** It only ever created a brand-new scope, which needs write on the global root (which the repair does fix), so it reported `PASS` while every feature-installed package was still un-updatable. It now asserts writability over every directory under the global root and drives the replace path by installing a second version over the first.
- **MAJOR — the guard false-passed when run as root**, since root can always write. It now refuses to run as root.
- **MINOR** — added an `EXIT`/`INT`/`TERM` trap in a subshell, so an interrupted run cannot leave a package and a PATH symlink in the image (`verify-tools.sh` is sourced, so a trap set in the function would have outlived it); `find -exec … +` cannot report failure, so setgid is applied through `xargs` and then asserted; `bin` is no longer chmodded recursively, which had widened write onto the Godot engine and a sudo-run script; `g+w` became `g+rwX` so a group-writable directory cannot be untraversable; the residue comment now matches the code.
- **NITs** — corrected "ownership stays with root", the over-generalised `ENOTEMPTY` claim, and a stale Dockerfile comment.

The reviewer's own negative results are as useful as its findings: it could not produce a false pass from the tarball-name or residue-assertion paths, confirmed the guards and idempotency, confirmed the offline claim, confirmed the probe is not vacuous, and found no dependency on the global root elsewhere in the repo.

Acting on the review changed the fix materially, not cosmetically: the original version would have shipped broken for `@anthropic-ai/claude-code` on every rebuild, guarded by a check that reported green while doing so.

## Outcome

- State: `findings-acted`
- Follow-ups:
  - #118 — `.llm/skills/testing/SKILL.md` is at 299/300 lines, so finding 4
    (validate a regression instrument with a single-variable control before
    trusting its red) could not be added there. Split the skill into
    `references/` and add it to the triple-proof section. Retrospectives/ is
    also at 32 files against a ~15 budget; distillation is overdue.
  - #119 — `verify.sh` should compare resolved paths for `core.hooksPath`
    instead of the literal string. Not fixed here: out of scope for this change.
