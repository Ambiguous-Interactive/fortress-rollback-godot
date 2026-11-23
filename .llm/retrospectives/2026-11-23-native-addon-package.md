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
- The first hosted Web jobs failed on both pins with `FileNotFoundError` at
  `.cache/reference/editors/<version>`. The platform exporter prepared its editor
  in another cache and the room witness expected an unpacked binary. The cold
  cache control now puts only the pinned ZIP in the selected cache, then executes
  the extracted editor's version command. The witness shares the pinned editor
  preparation path with the other reference tools.
- The first 4.3 simulator run reported `no completion after 160 ticks` after
  export and installation. A stationary local HTTP fixture reproduced the
  generic timeout. The witness now reports the slot, control, verified state and
  both peers' most recent frame and confirmation observations. The fixture
  reported Godot and Rust at frame 0 with confirmation at -1. The Linux
  exported matrix and stall witness still completed on both pins.
- A 4.7.2 browser wave physically closed a channel, then observed local frames
  38, 35, 39, and 39. The fixed 40-frame prefix no longer included the required
  later samples from every slot. The witness extends its confirmed comparison
  from 40 through the observed boundary, with a 128-frame recording cap.
  A delayed observation control captured frames 50, 47, 44, and 44. It compared
  52 canonical frames and every peer reported `disconnected` after the terminal
  interruption. The [browser witness guide](../skills/testing/references/browser-integration.md)
  records the boundary and correction rule.
- The hosted 4.3 direct-only eight-player cell started at 3.015–3.079 seconds,
  after the production fallback grace expired. Four clients used relay while
  direct links were still opening. The direct-only fixture now establishes full
  physical connectivity before entering the production start path and still
  requires zero relay sends. The missing-link cell keeps the production grace.

## Prune ledger

The online example and extension installation guides replace the earlier
instructions to install the two addon directories from separate sources.
Physical signing and device qualification remain under
[#452](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/452).

## Outcome

findings-acted
