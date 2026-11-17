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
from fetch import CACHE, load_manifest, sources
from run import setup_rust, rust_environment
from launch import execute, git_identity
from p2p_contract import validate, REVISION
from p2p_launch import FIXTURES, source, wrap_fixture

BINARY = CACHE / 'target/debug/p2p'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--only', choices=tuple(p2p_wrap.NAMES), help='regenerate one fixture, merging its digest into the manifest')
    args = parser.parse_args()
    identity = git_identity()
    manifest = load_manifest()
    # The oracle manifest resolves fortress-rollback through a cache path, so the
    # pinned upstream tree must exist before the build, exactly like the launchers.
    sources(manifest, args.offline)
    cargo, _ = setup_rust(manifest, args.offline)
    version = manifest['rust']['version']
    rust_dir = Path(__file__).resolve().parents[1] / 'oracle/rust/Cargo.toml'
    execute([str(cargo), '+' + version, 'build', '--locked', '--offline', '--manifest-path',
        str(rust_dir), '--bin', 'p2p'], CACHE / 'results/wrap-regenerate-build.log', timeout=600)
    digests = {}
    provenance_path = FIXTURES / 'MANIFEST.json'
    if args.only is not None:
        # A single-fixture regeneration merges into the committed manifest, so
        # every committed sibling fixture must exist and load cleanly before any
        # build rewrites one of them (fail-closed, not repair). A name the
        # committed manifest has never carried is a genuinely new profile with
        # nothing committed to corrupt, so it is skipped here and added by the
        # merge below; a manifest-named fixture missing from disk still refuses.
        if not provenance_path.exists():
            raise ValueError('--only needs the committed wrap-flood manifest; regenerate without --only first')
        committed_manifest = json.loads(provenance_path.read_text(encoding='utf-8'))
        if not isinstance(committed_manifest.get('fixtures'), dict) \
                or not isinstance(committed_manifest.get('provenance'), dict):
            raise ValueError('--only needs a well-formed committed wrap-flood manifest '
                             '(fixtures and provenance objects); regenerate without --only first')
        committed = committed_manifest['fixtures']
        for name in p2p_wrap.NAMES:
            if name != args.only and name + '.json' in committed:
                wrap_fixture(name)
    for name, (players, capacity, rounds, window, delays, layout, width) in p2p_wrap.PROFILES.items():
        if args.only is not None and name != args.only:
            continue
        scenario = p2p_wrap.build(str(BINARY), source, players, capacity, rounds, window, delays=delays,
                                  layout=layout, width=width)
        run = subprocess.run([str(BINARY)], input=json.dumps(scenario), capture_output=True,
                             encoding='utf-8', timeout=60, check=True, env=rust_environment())
        validate(json.loads(run.stdout), scenario, True)
        path = FIXTURES / (name + '.json')
        path.write_text(json.dumps(scenario, indent=2) + '\n', encoding='utf-8')
        digests[name + '.json'] = hashlib.sha256(path.read_bytes()).hexdigest()
    if args.only is None or not provenance_path.exists():
        provenance = {'format': 1, 'fixtures': digests, 'provenance': {
            'builder': 'scripts/oracle/p2p_wrap.py build()', 'upstream_revision': REVISION,
            'commit': identity['commit'], 'oracle_binary_sha256': hashlib.sha256(BINARY.read_bytes()).hexdigest(),
            'regenerate_with': 'python3 scripts/oracle/p2p_wrap_regenerate.py'}}
    else:
        # A single-fixture regeneration keeps the other committed digests and
        # refreshes only the provenance fields that describe this rebuild.
        provenance = json.loads(provenance_path.read_text(encoding='utf-8'))
        provenance['fixtures'].update(digests)
        provenance['provenance'].update({'upstream_revision': REVISION, 'commit': identity['commit'],
            'oracle_binary_sha256': hashlib.sha256(BINARY.read_bytes()).hexdigest()})
    provenance_path.write_text(json.dumps(provenance, indent=2) + '\n', encoding='utf-8')
    # Every committed schedule must still match the launcher's load-time contract;
    # names the manifest does not carry are genuinely new profiles a sibling --only
    # invocation has not added yet, so they are added (and verified) by their own run.
    merged_names = json.loads(provenance_path.read_text(encoding='utf-8')).get('fixtures', {})
    for name in p2p_wrap.NAMES:
        if name + '.json' in merged_names:
            wrap_fixture(name)
    print('regenerated', len(digests), 'wrap fixtures:', ' '.join(sorted(digests)))


if __name__ == '__main__':
    main()
