# Install an addon candidate

Build an addon-only archive from a repository checkout with Python 3.12 or later:

```sh
python3 scripts/package_addon.py --output .cache/reference/packages/fortress-addon-candidate.tar
```

The command prints the archive's SHA-256 digest and file count. The uncompressed
tar contains only `addons/fortress_rollback/`, including the runtime GDScript,
script UIDs, MIT license, runtime notice and upstream MIT license. It excludes
examples, tests, downloaded SDKs, native extensions and development tools.
The explicit runtime script manifest in `scripts/package_addon.py` requires every
core, protocol and transport script. Unknown files, symlinks, special files and
missing or changed licenses fail the build. Paired script UIDs are optional.
Update the manifest when intentionally adding or removing runtime scripts. Existing output is replaced atomically after a successful build.

Archives use sorted paths, fixed permissions, zero timestamps and empty owner
names. Identical source bytes produce identical archives, regardless of source
file timestamps, permissions or checkout location. A candidate identifies source
bytes; it does not establish a supported release or complete A5.

## Install in a game

Extract the archive at the root of a Godot 4.3 or later project:

```sh
tar -xf fortress-addon-candidate.tar -C /path/to/game
```

The resulting path must be `res://addons/fortress_rollback/`. No editor plugin
activation, autoload, Rust toolchain, C# support or native extension is required.
Start with the [integration guide](integration.md) and
[peer session guide](peer-session.md).

The archive includes optional SignalFish adapters. Every adapter parses without
installing the SignalFish SDK. A game using those adapters must supply the SDK
objects described in [SignalFish membership](signalfish-membership.md).
For a complete online example with its separate SDK installation, follow the
[online example guide](online-example.md). The SDK and its license are not
redistributed in this archive.

## Verify a candidate locally

Run the clean-project audit from the same checkout:

```sh
python3 scripts/reference/package_audit.py \
  --godot /path/to/godot \
  --output .cache/reference/packages/verified
python3 scripts/reference/test_package_audit.py --godot /path/to/godot -v
python3 -m unittest discover -s scripts/reference -p 'test_package*.py' -v
```

The audit builds `fortress-addon-candidate.tar`, verifies the archived bytes,
then extracts them into a temporary Godot project. That project contains only
the installed addon, minimal project settings and the audit script. It loads
every runtime script without the SDK, advances one local driver tick, runs
70 frames between two byte peers, exchanges checksum and quality messages,
checks terminal timeout behavior, and plays one confirmed spectator frame.
The spectator smoke also refuses local input and waits when host data is missing.

`package-audit.json` records success, archive and engine hashes, and archive
paths. `clean-addon.log` records engine output. A failure clears the prior
success receipt. The negative control adds a missing SDK preload to an existing
adapter and confirms that the clean install fails; repairing it must pass.
The builder tests also verify reproducibility under changed host metadata and
reject missing scripts or transport families, native files, orphan UIDs and
development scripts.

CI runs packaging controls and the clean audit with the pinned minimum and
current engines. The audit does not verify native platform exports, browser
networking, public hosting or the remaining [release gates](../PLAN.md).
