"""Bind the native profile to the complete source trees of the verified archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tomllib

CONTRACTS = {
    'd124c89080004d96971a629bb0427056ee1805e3': (2, 1, '83a80b4d0615245733f765f7fb46535e922dbb6e5db3e95320946a290ef5ba68'),
    '25e8020d1a5fd40c4f16b37f97b5ec5329a8566d': (6, 6, '1bfd857b56c13fed094fbd15bb656dc00b22a56e5ac8fd8262488a4af871fbfa'),
}


def tree_digest(root):
    entries = []
    for path in sorted(root.rglob('*'), key=lambda item: item.relative_to(root).as_posix()):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError(f'unexpected native Fortress source entry: {path}')
        digest = None
        if path.is_file():
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        entries.append([path.relative_to(root).as_posix(), digest])
    return hashlib.sha256(json.dumps(entries, separators=(',', ':')).encode('ascii')).hexdigest()


def verify_source(manifest):
    with manifest.open('rb') as stream:
        source = manifest.parent / tomllib.load(stream)['dependencies']['fortress-rollback']['path']
    revision = source.name.removeprefix('fortress-rollback-')
    if source.name != 'fortress-rollback-' + revision or revision not in CONTRACTS:
        raise ValueError('unsupported native Fortress source root')
    wire, generation, expected = CONTRACTS[revision]
    if tree_digest(source.resolve(strict=True)) != expected:
        raise ValueError(f'native Fortress source differs from the verified archive for {revision}')
    return revision, wire, f'fortress-native-{revision[:8]}-v{generation}-u32'


def build_verified(manifest, options, environment=None, *, target=None, target_dir=None):
    before = verify_source(manifest)
    selection = ['--manifest-path', manifest, '--locked', '--release']
    if target is not None:
        selection.extend(['--target', target])
    if target_dir is not None:
        selection.extend(['--target-dir', target_dir])
    # A failed parallel build can cache its dependency before source verification exits.
    subprocess.run(['cargo', 'clean', '-p', 'fortress-rollback', *selection], env=environment, check=True)
    subprocess.run(['cargo', 'build', *selection, *options], env=environment, check=True)
    if verify_source(manifest) != before:
        raise ValueError('native Fortress source changed during the build')


def main():
    if len(sys.argv) > 1:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('command', choices=('check', 'build-web'))
        parser.add_argument('manifest', type=Path)
        args = parser.parse_args()
        if args.command == 'check':
            verify_source(args.manifest)
        else:
            build_verified(args.manifest, ['--features', 'web', '--lib', '-Zbuild-std'], target='wasm32-unknown-emscripten')
        return
    _, wire, profile = verify_source(Path('Cargo.toml'))
    output = Path(os.environ['OUT_DIR']) / 'native_wire.rs'
    output.write_text(f'const PROFILE: &str = "{profile}";\nconst WIRE_VERSION: u8 = {wire};\n', encoding='utf-8')


if __name__ == '__main__':
    main()
