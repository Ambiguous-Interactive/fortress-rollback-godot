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
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/reference'))

from fetch import CACHE, digest, load_manifest, sources  # noqa: E402
from receipt_arguments import ReceiptParser  # noqa: E402
from spectator_model import REVISION, SPEC, ensure_jar, check  # noqa: E402


def main():
    parser = ReceiptParser(description=__doc__, receipt='receipt.json')
    parser.add_argument('--godot', help='also replay production Godot observations through the pinned model')
    parser.add_argument('--tlc-jar', type=Path, default=CACHE / 'tla2tools.jar')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/spectator-model')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'receipt.json'
    receipt.unlink(missing_ok=True)
    manifest = load_manifest()
    if manifest['sources']['fortress']['revision'] != REVISION:
        raise ValueError('spectator adapter revision differs from pinned source')
    sources(manifest)
    files = [*(ROOT / 'scripts/oracle').glob('*.py'), ROOT / 'tests/oracle/spectator_trace.gd',
             *(ROOT / 'addons/fortress_rollback/core').glob('*.gd'),
             *(ROOT / 'scripts/reference').glob('*.py'), ROOT / 'docs/reference/pins.json',
             ROOT / 'scripts/oracle/tools/tla2tools-94d0c507.jar',
             *(ROOT / 'scripts/oracle/rust').rglob('*.rs'),
             ROOT / 'scripts/oracle/rust/Cargo.toml', ROOT / 'scripts/oracle/rust/Cargo.lock']
    source_hashes = {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}
    ensure_jar(args.tlc_jar)
    formal = check(args.output, args.tlc_jar.resolve())
    runtime = None
    if args.godot:
        from engine_path import resolve_engine
        from spectator_runtime import check as check_runtime
        runtime = check_runtime(resolve_engine(args.godot), args.output / 'runtime', args.tlc_jar.resolve(), ROOT)
        if any(outcome['model_sha256'] != formal['spec_sha256']
               for trace in runtime['traces'] for kind, outcome in trace.items()
               if kind in ('positive', 'illegal_advance', 'preplay_divergence')):
            raise ValueError('pinned spectator model changed during runtime projection')
    ensure_jar(args.tlc_jar)
    result = {'format': 1, 'complete': True, 'passed': True,
              'upstream_revision': manifest['sources']['fortress']['revision'],
              'manifest_sha256': digest(ROOT / 'docs/reference/pins.json'),
              'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, encoding='utf-8').strip(),
              'working_tree_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True, encoding='utf-8')),
              'platform': platform.platform(), 'formal': formal, 'runtime': runtime, 'source_sha256': source_hashes,
              'limitations': [
                  'Godot projection covers no delay and binary input for one active slot; Rust compares catch-up speeds one and two.' if runtime else
                  'Upstream SpectatorSession model only; no Godot observation requested.',
                  'Synthetic sync preconditions do not establish runtime handshake, events, expiry or status parity.',
                  'No live SignalFish spectator routing is established (see #131).']}
    if source_hashes != {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}:
        raise ValueError('source changed during spectator model gate; rerun')
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    print(f"Spectator model parity: pinned {REVISION[:12]} {SPEC} verifies; unsafe mutant rejected")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
