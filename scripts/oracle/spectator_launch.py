#!/usr/bin/env python3
"""Check the pinned SpectatorSession model and optional production Godot traces.

Runs the reviewed TLC jar on `specs/tla/SpectatorSession.tla` from the verified
upstream tree to confirm its safety invariants, then runs a deliberately unsafe
behavior mutant and requires TLC to reject it. With --godot, replay actual playback observations through the
pinned Next relation. This makes no live-transport or SignalFish claim.
"""
import json
from pathlib import Path
import platform
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/reference'))

from fetch import CACHE, digest, load_manifest, sources  # noqa: E402
from launch import git_identity, require_unchanged  # noqa: E402
from receipt_arguments import ReceiptParser  # noqa: E402
from source_build import upstream_inventory  # noqa: E402
from source_wire import wire_version  # noqa: E402
from spectator_model import CONFIG, SPEC, check  # noqa: E402
from tlc_artifact import ARTIFACT, ensure_jar  # noqa: E402


def main():
    parser = ReceiptParser(description=__doc__, receipt='receipt.json', output_owner='formal-oracle')
    parser.add_argument('--godot', help='also replay production Godot observations through the pinned model')
    parser.add_argument('--tlc-jar', type=Path, default=CACHE / 'tla2tools.jar')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/spectator-model')
    args = parser.parse_args()
    with parser.claim_output(args.output):
        return run(args)


def run(args):
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'receipt.json'
    receipt.unlink(missing_ok=True)
    identity = git_identity()
    files = [*(ROOT / 'scripts/oracle').glob('*.py'), ROOT / 'tests/oracle/spectator_trace.gd',
             *(ROOT / 'addons/fortress_rollback/core').glob('*.gd'),
             *(ROOT / 'scripts/reference').glob('*.py'), ROOT / 'docs/reference/pins.json',
             *(ROOT / 'scripts/oracle/rust').rglob('*.rs'),
             ROOT / 'scripts/oracle/rust/Cargo.toml', ROOT / 'scripts/oracle/rust/Cargo.lock']
    source_hashes = {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}
    manifest = load_manifest()
    artifact = manifest['artifacts'][ARTIFACT]
    jar_source, jar_digest = ROOT / artifact['repository_path'], artifact['digest']
    revision = manifest['sources']['fortress']['revision']
    wire_version(revision)
    upstream = sources(manifest)['fortress']
    model_paths = (upstream / SPEC, upstream / CONFIG)
    model_hashes = {path: digest(path) for path in model_paths}
    upstream_hashes = upstream_inventory(upstream) if args.godot else None
    ensure_jar(args.tlc_jar, jar_source, jar_digest)
    files.append(jar_source)
    source_hashes[str(jar_source.relative_to(ROOT))] = jar_digest
    formal = check(args.output, args.tlc_jar.resolve(), upstream=upstream)
    runtime = None
    if args.godot:
        from engine_path import resolve_engine
        from spectator_runtime import check as check_runtime
        runtime = check_runtime(resolve_engine(args.godot), args.output / 'runtime', args.tlc_jar.resolve(), ROOT, manifest=manifest, upstream=upstream)
        if any(outcome['model_sha256'] != formal['spec_sha256']
               for trace in runtime['traces'] for kind, outcome in trace.items()
               if kind in ('positive', 'illegal_advance', 'preplay_divergence')):
            raise ValueError('pinned spectator model changed during runtime projection')
    ensure_jar(args.tlc_jar, jar_source, jar_digest)
    require_unchanged('TLC artifact', jar_digest, formal['TLC_sha256'])
    result = {'format': 1, 'complete': True, 'passed': True,
              'upstream_revision': revision,
              'manifest_sha256': source_hashes['docs/reference/pins.json'],
              'commit': identity['commit'],
              'working_tree_dirty': identity['working_tree_dirty'],
              'platform': platform.platform(), 'formal': formal, 'runtime': runtime, 'source_sha256': source_hashes,
              'limitations': [
                  'Formal projection covers no delay; actual Rust/Godot comparison also covers bounded stream delay and catch-up speeds one and two.' if runtime else
                  'Upstream SpectatorSession model only; no Godot observation requested.',
                  'Synthetic sync preconditions do not establish runtime handshake, events, expiry or status parity.',
                  'No live SignalFish spectator routing is established (see #131).']}
    require_unchanged('SpectatorSession model inventory', model_hashes, {path: digest(path) for path in model_paths})
    if upstream_hashes is not None:
        require_unchanged('upstream Rust source inventory', upstream_hashes, upstream_inventory(upstream))
    require_unchanged('local source inventory', source_hashes, {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)})
    require_unchanged('repository identity', identity, git_identity())
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    print(f"Spectator model parity: pinned {revision[:12]} {SPEC} verifies; unsafe mutant rejected")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
