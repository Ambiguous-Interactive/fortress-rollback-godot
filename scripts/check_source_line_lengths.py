#!/usr/bin/env python3
"""Enforce the 180-column limit across tracked and new repository source files."""

import argparse
from pathlib import Path
import subprocess


MAX_COLUMNS = 180
SOURCE_SUFFIXES = {
    '.gd', '.gdshader', '.gdextension', '.py', '.sh', '.bash', '.js', '.cjs', '.mjs',
    '.ts', '.tsx', '.jsx', '.json', '.yaml', '.yml', '.toml', '.cfg', '.ini',
    '.godot', '.tscn', '.tres', '.html', '.css', '.scss', '.sql', '.xml', '.svg',
    '.c', '.h', '.cpp', '.hpp', '.cs', '.rs',
}
SOURCE_NAMES = {'Dockerfile', 'Makefile', '.editorconfig', '.gitattributes', 'gdformatrc', 'gdlintrc'}
# Generated upstream excerpts and dependency receipts preserve verbatim provenance,
# including indivisible strings. They are data artifacts, not authored source.
DATA_ARTIFACTS = {'docs/reference/parity-ledger.json', '.devcontainer/devcontainer-lock.json'}


def is_source(path: Path) -> bool:
    if path.as_posix() in DATA_ARTIFACTS:
        return False
    return path.suffix in SOURCE_SUFFIXES or path.name in SOURCE_NAMES or path.parts[0] == '.githooks'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    root = parser.parse_args().root.resolve()
    paths = subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    ).decode('utf-8').split('\0')
    failures = 0
    checked = 0
    for name in sorted(set(paths) - {''}):
        relative = Path(name)
        path = root / relative
        if not is_source(relative) or not path.is_file():
            continue
        checked += 1
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            if len(line) > MAX_COLUMNS:
                print(f'{name}:{number}: {len(line)} columns exceeds {MAX_COLUMNS}')
                failures += 1
    print(f'Source line lengths: {checked} files checked; {failures} violations (maximum {MAX_COLUMNS}).')
    return int(failures > 0)


if __name__ == '__main__':
    raise SystemExit(main())
