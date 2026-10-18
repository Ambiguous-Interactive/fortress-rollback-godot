# Session 032: npm global packages user-updatable

`npm install -g @openai/codex` failed with `EACCES ... rename`, and the
reported scope was wider than the symptom: no global npm package could be
installed, updated or removed by the container user.

## Root cause

The Dockerfile installs every agentic CLI from npm's global prefix (`/usr/local`)
as root, leaving `lib/node_modules` and `bin` as `root:root 0755`. The container
runs as `vscode`, and on Unix replacing or removing a file needs write permission
on its **parent** directory. Three distinct operations were broken: `mkdir` for a
new package, `rename` for an update and for a removal. Read-only npm commands
kept working throughout, which is why the breakage stayed hidden. `npm doctor`
reports every permission check `Ok` here: it flags group/world-writable
directories, never "not writable by me", so it was rejected as an oracle.

Reproduced all three failures as `vscode`, then isolated the cause to one
variable: the same probe against a user-writable prefix passed, and against
`/usr/local` failed.

## Fix

`npm-global-perms.sh` grants group write plus setgid for `vscode`'s own primary
group, applied recursively under `lib/node_modules` (where npm extracts and empties
package trees) but to the `bin` **directory** only (npm only creates and unlinks
symlinks there). This keeps a single global root, so `npm root -g`, `PATH` and
every existing binary are untouched. It grants no new privilege — `vscode`
already has passwordless sudo.

Two alternatives were rejected on evidence. npm's own guidance is to use a Node
version manager, but that makes global binaries depend on a shell-initialised
`PATH` and would break MCP servers spawned without a login shell. A user-level
prefix would shadow root-installed binaries, duplicate roughly a gigabyte of
native packages, and break the existing Codex package-layout check.

Codex moved 0.162.1 → 0.163.0 from the original failing command. `claude`,
`opencode` and `godot-mcp` were confirmed intact and updatable.

## The bug the review found in the fix

The first version was wrong in a way its own guard could not see. Devcontainer
features are appended as layers **after** the Dockerfile, and the claude-code
feature installs a global npm package as root — so the Dockerfile repair never
covered `@anthropic-ai/claude-code`, and every rebuild reintroduced the original
`EACCES` for it while the Dockerfile-installed CLIs stayed fixed.

Worse, the regression check reported `PASS` in exactly that state, because it
only ever created a brand-new scope. Creating `@newscope/pkg` needs write on the
global root, which the repair does fix; replacing `@oldscope/pkg` needs write on
`@oldscope`, which it does not. The check also false-passed when run as root,
since root can always write.

Both are fixed. `post-create.sh` re-applies the repair after features run, and
the check now asserts writability over every directory under the global root,
installs a second version over the first to drive the replace path, and refuses
to run as root.

## Review

A fresh-context adversarial review, given the diff and the problem statement but
explicitly barred from reading the retrospective or knowledge store, returned
**DO-NOT-SHIP**: one blocker, two majors, four minors and four nits. All were
reproduced before any were acted on, and all were accepted. See the
[retrospective](../.llm/retrospectives/2026-10-18-npm-global-permissions.md).

Two of my own instruments had already lied earlier in the session — a residue
assertion that flagged npm's normal empty-scope behaviour, and a guessed tarball
name that failed with "tarball seems to be corrupted" instead of exercising the
permission check. The reviewer's control experiment is what made both visible,
and finding 4 in the retrospective records the rule that belongs in the testing
skill.

Follow-ups: #118 (the testing skill is at 299/300 lines, so it cannot accept that
rule; retrospectives/ is also over budget) and #119 (`core.hooksPath` comparison).

## Validation

- Triple proof: red at `HEAD`, passes on a writable prefix, green after repair.
- `bash .devcontainer/post-create.sh` end to end: exit 0, **30 passed, 0 failed**.
- `shellcheck -S warning .devcontainer/*.sh` (CI's exact step): clean.
- `shellcheck -S style` on the repair script: clean. `make lint-source`,
  `make lint-llm`, `make test-llm`: green.
- The Dockerfile change cannot be built here (no Docker daemon). `Devcontainer
  Verify` builds the image on x64 and arm64, so CI validates it.

One pre-existing failure was found and is not fixed here: the git-hooks check
compares `core.hooksPath` to the literal string `.githooks` (#119). Local drift
made it red at pristine `HEAD`; `make hooks` restored it.

Retro: findings-acted.
