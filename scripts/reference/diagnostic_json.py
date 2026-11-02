#!/usr/bin/env python3
"""Strictly decode production diagnostic exports and replay their decoded canonical windows."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def reject_constant(value: str) -> None:
    raise ValueError('non-JSON numeric constant: ' + value)


def run(godot: str, phase: str, output: Path) -> None:
    result = subprocess.run([godot, '--headless', '--path', str(ROOT), '--script',
                             'scripts/reference/diagnostic_json_probe.gd', '--', phase, str(output)],
                            capture_output=True, encoding='utf-8', errors='strict', timeout=30, check=True)
    if 'SCRIPT ERROR' in result.stdout + result.stderr or 'ERROR:' in result.stdout + result.stderr:
        raise ValueError('diagnostic JSON probe emitted engine errors')
    marker = 'FORTRESS_DIAGNOSTIC_JSON_' + ('EXPORT 36' if phase == 'export' else 'PLAYBACK 36')
    if marker not in result.stdout:
        raise ValueError('diagnostic JSON probe did not complete ' + phase)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True)
    args = parser.parse_args()
    scratch = ROOT / '.cache/scratch'
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='diagnostic-json-', dir=scratch) as temporary:
        output = Path(temporary)
        run(args.godot, 'export', output)
        values = ['', 'ordinary', 'Unicode 日本語 café 😀', 'quotes " and slash \\ and literal \\v and \\\\v']
        values += [chr(code) for code in range(1, 32)] + [chr(1) * 128]
        for index, value in enumerate(values):
            raw = (output / f'report-{index}.json').read_bytes()
            report = json.loads(raw, parse_constant=reject_constant)
            compact = json.loads((output / f'compact-{index}.json').read_bytes(), parse_constant=reject_constant)
            if compact != report:
                raise ValueError(f'compact and pretty reports disagree in report {index}')
            trace = report['trace']
            for field in ('seed', 'application_version', 'replay_command'):
                expected = value * 4 if field == 'replay_command' and index == len(values) - 1 else value
                if trace[field] != expected:
                    raise ValueError(f'metadata changed in report {index}, {field}')
            if report['failure'] != {'reason': value, 'nested': [{value: value}]}:
                raise ValueError(f'failure dictionaries changed in report {index}')
            if len(trace['frames']) != 4 or trace['retained_payload_bytes'] > trace['max_payload_bytes'] or len(raw) > trace['max_export_bytes']:
                raise ValueError('canonical window exceeded its configured bounds')
            (output / f'decoded-{index}.json').write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
        failure = json.loads((output / 'replay-failure.json').read_bytes(), parse_constant=reject_constant)
        if failure['failure']['frame'] != 8 or failure['failure']['comparison'] != 'state_checksum' or failure['recording']['seed'] != '1701':
            raise ValueError('replay failure export lost its failure domain or recording metadata')
        run(args.godot, 'playback', output)
    print('Diagnostic JSON: 36 pretty/compact exports, exact metadata/failure values, 144 canonical states, replay failure report.')


if __name__ == '__main__':
    main()
