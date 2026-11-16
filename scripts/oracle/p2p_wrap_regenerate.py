#!/usr/bin/env python3
"""Regenerate the committed wrap-flood fixtures with the pinned oracle binary.

Run this deliberately when the corpus's builder or the oracle changes: it
rebuilds every wrap-flood schedule through p2p_wrap.build() (whose per-round
model checks still fail the build on divergence), verifies each scenario on
the current binary, and rewrites the fixture files and MANIFEST.json digests.
The launchers never invoke this: they load the committed schedules and run
the full differential gates against them.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'reference'))
import p2p_wrap
from fetch import CACHE, load_manifest
from run import setup_rust, rust_environment
from launch import execute, git_identity
from p2p_contract import validate, REVISION
from p2p_launch import FIXTURES, source, wrap_fixture

BINARY = CACHE / 'target/debug/p2p'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    identity = git_identity()
    manifest = load_manifest()
    cargo, _ = setup_rust(manifest, args.offline)
    version = manifest['rust']['version']
    rust_dir = Path(__file__).resolve().parents[1] / 'oracle/rust/Cargo.toml'
    execute([str(cargo), '+' + version, 'build', '--locked', '--offline', '--manifest-path',
        str(rust_dir), '--bin', 'p2p'], CACHE / 'results/wrap-regenerate-build.log', timeout=600)
    digests = {}
    for name, (players, capacity, rounds) in p2p_wrap.PROFILES.items():
        scenario = p2p_wrap.build(str(BINARY), source, players, capacity, rounds)
        run = subprocess.run([str(BINARY)], input=json.dumps(scenario), capture_output=True,
                             encoding='utf-8', timeout=60, check=True, env=rust_environment())
        validate(json.loads(run.stdout), scenario, True)
        path = FIXTURES / (name + '.json')
        path.write_text(json.dumps(scenario, indent=2) + '\n', encoding='utf-8')
        digests[name + '.json'] = hashlib.sha256(path.read_bytes()).hexdigest()
    provenance = {'format': 1, 'fixtures': digests, 'provenance': {
        'builder': 'scripts/oracle/p2p_wrap.py build()', 'upstream_revision': REVISION,
        'commit': identity['commit'], 'oracle_binary_sha256': hashlib.sha256(BINARY.read_bytes()).hexdigest(),
        'regenerate_with': 'python3 scripts/oracle/p2p_wrap_regenerate.py'}}
    (FIXTURES / 'MANIFEST.json').write_text(json.dumps(provenance, indent=2) + '\n', encoding='utf-8')
    # Every committed schedule must still match the launcher's load-time contract.
    for name in p2p_wrap.NAMES:
        wrap_fixture(name)
    print('regenerated', len(digests), 'wrap fixtures:', ' '.join(sorted(digests)))


if __name__ == '__main__':
    main()
