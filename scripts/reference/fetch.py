#!/usr/bin/env python3
"""Fetch immutable development references; reject corrupt caches even offline."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / '.cache/reference'
MANIFEST = ROOT / 'docs/reference/pins.json'


def load_manifest(path=MANIFEST):
    data = json.loads(path.read_text())
    if data.get('schema_version') != 1:
        raise ValueError('unsupported pin manifest schema')
    for name, source in data['sources'].items():
        if not re.fullmatch(r'[0-9a-f]{40}', source['revision']):
            raise ValueError(f'{name}: missing or invalid source revision')
        if not source['archive']['url'].endswith('/' + source['revision']):
            raise ValueError(f'{name}: archive URL disagrees with revision')
    for pin in [s['archive'] for s in data['sources'].values()] + list(data['artifacts'].values()):
        size = {'sha256': 64, 'sha512': 128}.get(pin['algorithm'])
        if size is None or not re.fullmatch('[0-9a-f]{' + str(size) + '}', pin['digest']):
            raise ValueError('invalid artifact digest')
    return data


def digest(path, algorithm='sha256'):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


def fetch(pin, name, offline=False, cache=CACHE):
    destination = cache / 'downloads' / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    repository_source = ROOT / pin['repository_path'] if 'repository_path' in pin else None
    if repository_source is not None:
        verify(repository_source, pin)
    if not destination.exists():
        if offline and repository_source is None:
            raise FileNotFoundError(f'offline cache miss: {destination}')
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            try:
                if repository_source is not None:
                    with repository_source.open('rb') as source:
                        shutil.copyfileobj(source, output)
                else:
                    with urllib.request.urlopen(pin['url'], timeout=60) as response:
                        shutil.copyfileobj(response, output)
                output.close()
                verify(temporary, pin)
                temporary.replace(destination)
            finally:
                temporary.unlink(missing_ok=True)
    verify(destination, pin)
    return destination


def verify(path, pin):
    actual = digest(path, pin['algorithm'])
    if actual != pin['digest']:
        raise ValueError(f'digest mismatch: {path}: expected {pin["digest"]}, got {actual}')


def same_tree(expected, actual):
    """Compare all entries and bytes; metadata alone never establishes source integrity."""
    if not actual.is_dir() or actual.is_symlink():
        return False
    left = {path.relative_to(expected): path for path in expected.rglob('*')}
    right = {path.relative_to(actual): path for path in actual.rglob('*')}
    if left.keys() != right.keys():
        return False
    for relative, path in left.items():
        other = right[relative]
        if path.is_symlink() or other.is_symlink():
            if not (path.is_symlink() and other.is_symlink() and path.readlink() == other.readlink()):
                return False
        elif path.is_dir():
            if not other.is_dir():
                return False
        elif not other.is_file() or path.stat().st_mode != other.stat().st_mode or digest(path) != digest(other):
            return False
    return True


def retain_verified_tree(expected, destination):
    """Keep unchanged mtimes for Cargo; replace any altered extraction from verified bytes."""
    if same_tree(expected, destination):
        return
    if destination.is_symlink() or destination.is_file():
        destination.unlink()
    elif destination.exists():
        shutil.rmtree(destination)
    shutil.move(str(expected), destination)


def sources(data, offline=False, cache=CACHE):
    """Re-extract verified archives and retain only byte-identical source caches."""
    result = {}
    for name, source in data['sources'].items():
        archive = fetch(source['archive'], name + '.tar.gz', offline, cache)
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            with tarfile.open(archive) as tar:
                members = tar.getmembers()
                if not members or any(m.name.split('/')[0] != source['root'] for m in members):
                    raise ValueError(f'{name}: unexpected source archive root')
                tar.extractall(temporary, filter='data')
            destination = cache / source['root']
            retain_verified_tree(Path(temporary) / source['root'], destination)
        result[name] = destination
        print(f'{name}: verified {source["revision"]} {source["archive"]["digest"]}')
    lock = result['fortress'] / 'Cargo.lock'
    if digest(lock) != data['rust']['lockfile_sha256']:
        raise ValueError('Fortress Cargo.lock differs from reviewed pin')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--artifact', help='download one named tools artifact instead of sources')
    args = parser.parse_args()
    data = load_manifest()
    if args.artifact:
        print(fetch(data['artifacts'][args.artifact], args.artifact, args.offline))
    else:
        sources(data, args.offline)


if __name__ == '__main__':
    main()
