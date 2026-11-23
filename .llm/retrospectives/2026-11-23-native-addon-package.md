# Install the complete prebuilt native addon

## Work under review

The target archive installs the GDScript runtime and the native extension together.
The headless driver and online room witnesses install both addon directories from
the archive.

## Findings and actions

- The focused archive test failed against the original installer. It accepted a
  binary-only addon and rejected the same extension with the required runtime
  included. The Web stage now starts without a checkout copy of the addon.
  The [infrastructure evidence guide](../skills/testing/references/infrastructure.md)
  records the clean-install boundary.
- The independent review found that the archive inventory ignored directory
  entries and that Python exposes a normalized filename as well as the original
  ZIP name. A new fixture reproduced acceptance of an unexpected runtime
  directory. The installer now checks original names and the full runtime inventory.
- `python3 experiments/gdextension/export.py <version> <target>` produced Linux and
  Web exports for both engine pins. All four commands reported
  `missing-library control exited 23`. Comparing each archive to the canonical
  snapshot found 105 exact runtime files.
- Godot's [extension manifest reference](https://docs.godotengine.org/en/stable/engine_details/engine_api/gdextension/gdextension_file.html)
  specifies how feature tags select libraries. The package retains the existing
  target manifests and the Web export guide now links the engine's
  [hosting requirements](https://docs.godotengine.org/en/4.3/tutorials/export/exporting_for_web.html#thread-and-extension-support).
- The first reference run overlapped a live browser lease and an edit. Its
  source snapshot controls hit their 30-second process limit, and two runner
  controls reported `source_changed`. These controls share the host lease and
  read the checkout, so run them after the browser wave with the sources frozen.

## Prune ledger

The online example and extension installation guides replace the earlier
instructions to install the two addon directories from separate sources.
Physical signing and device qualification remain under
[#452](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/452).

## Outcome

findings-acted
