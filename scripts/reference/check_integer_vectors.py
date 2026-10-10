#!/usr/bin/env python3
"""Rebuild the independent integer oracle offline with cached pinned Rust."""

import argparse
import subprocess

from fetch import CACHE, ROOT, load_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--write', action='store_true', help='replace checked-in golden vectors')
    mode.add_argument('--check', action='store_true', help='check vector freshness (the default)')
    args = parser.parse_args()
    version = load_manifest()['rust']['version']
    candidates = sorted((CACHE / 'rustup/toolchains').glob(f'{version}-*/bin/rustc'))
    if len(candidates) != 1:
        raise FileNotFoundError(f'expected one cached Rust {version} compiler; run make reference-baseline first')
    rustc = candidates[0]
    actual = subprocess.check_output([str(rustc), '--version'], text=True).strip()
    if not actual.startswith(f'rustc {version} '):
        raise ValueError(f'unexpected compiler: {actual}')
    directory = CACHE / 'integer'
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / 'vectors'
    subprocess.run([str(rustc), '--edition', '2021', str(ROOT / 'scripts/reference/integer_vectors.rs'), '-o', str(binary)], check=True)
    expected = subprocess.check_output([str(binary)])
    destination = ROOT / 'tests/determinism/integer_vectors.json'
    if args.write:
        destination.write_bytes(expected)
    elif destination.read_bytes() != expected:
        raise ValueError('integer vectors differ from the independent Rust oracle; investigate before updating')
    print(f'Integer vectors: independent {actual}; exact fixture match.')


if __name__ == '__main__':
    main()
