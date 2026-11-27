#!/usr/bin/env bash
set -eu

# Run with emsdk 3.1.74 active and the pinned nightly's cargo and rustc on PATH.
root=$(git rev-parse --show-toplevel)
export CARGO_TARGET_DIR="$root/.cache/reference/target/gdextension"
manifest="$root/experiments/gdextension/Cargo.toml"
target=wasm32-unknown-emscripten
flags="-C target-feature=-crt-static -C relocation-model=pic -C link-args=-sSIDE_MODULE=2"
flags+=" -C llvm-args=-enable-emscripten-cxx-exceptions=0 -Z emscripten-wasm-eh=false"
export CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_RUSTFLAGS="$flags -Z default-visibility=hidden -Z link-native-libraries=no"
python3 "$root/experiments/gdextension/verify_source.py" check "$manifest"
tree=$(cargo tree --locked --manifest-path "$manifest" --target "$target" --features web -e normal --prefix none)
if grep -Eq '^(wasm-bindgen|js-sys|web-sys)' <<<"$tree"; then
    echo "Browser JS dependency in the Godot side module" >&2
    exit 1
fi
# Require the build to produce the requested module.
rm -f "$CARGO_TARGET_DIR/$target/release/fortress_gdextension_experiment.wasm"
python3 "$root/experiments/gdextension/verify_source.py" build-web "$manifest"
test -s "$CARGO_TARGET_DIR/$target/release/fortress_gdextension_experiment.wasm"
