#!/usr/bin/env python3
"""Model-check the pinned upstream SpectatorSession spec and record a source-bound receipt.

Runs the reviewed TLC jar on `specs/tla/SpectatorSession.tla` from the verified
upstream tree to confirm its safety invariants, then runs a deliberately unsafe
behavior mutant and requires TLC to reject it. This is the model-side half of
issue #131 acceptance #5; it makes no live-transport or SignalFish claim.
"""
import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/reference'))

from fetch import CACHE, digest, load_manifest  # noqa: E402
from receipt_arguments import ReceiptParser  # noqa: E402
from spectator_model import REVISION, SPEC, ensure_jar, check  # noqa: E402


def main():
    parser = ReceiptParser(description=__doc__, receipt='receipt.json')
    parser.add_argument('--godot', help='unused; accepted so the oracles job shares one invocation shape')
    parser.add_argument('--tlc-jar', type=Path, default=CACHE / 'tla2tools.jar')
    parser.add_argument('--output', type=Path, default=CACHE / 'results/spectator-model')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = args.output / 'receipt.json'
    receipt.unlink(missing_ok=True)
    ensure_jar(args.tlc_jar)
    formal = check(args.output, args.tlc_jar.resolve())
    manifest = load_manifest()
    files = [ROOT / 'scripts/oracle/spectator_model.py', ROOT / 'scripts/oracle/spectator_launch.py',
             ROOT / 'scripts/reference/receipt_arguments.py', ROOT / 'docs/reference/pins.json',
             ROOT / 'scripts/oracle/tools/tla2tools-94d0c507.jar']
    source_hashes = {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}
    result = {'format': 1, 'complete': True, 'passed': True,
              'upstream_revision': manifest['sources']['fortress']['revision'],
              'manifest_sha256': digest(ROOT / 'docs/reference/pins.json'),
              'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, encoding='utf-8').strip(),
              'working_tree_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True, encoding='utf-8')),
              'platform': platform.platform(), 'formal': formal, 'source_sha256': source_hashes,
              'limitations': [
                  'Upstream SpectatorSession model only; the Godot tier is not projected into the model.',
                  'Signals the fixed-membership model, not live SignalFish spectator routing (see #131).']}
    if source_hashes != {str(p.relative_to(ROOT)): digest(p) for p in sorted(files)}:
        raise ValueError('source changed during spectator model gate; rerun')
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    print(f"Spectator model parity: pinned {REVISION[:12]} {SPEC} verifies; unsafe mutant rejected")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
