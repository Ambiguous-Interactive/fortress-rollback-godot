#!/usr/bin/env python3
"""Validate one complete P2P observation against its original submitted scenario."""
import argparse
import json
from pathlib import Path
import sys
from p2p_contract import validate, validate_scenario, compare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scenario', required=True, type=Path)
    parser.add_argument('--source', action='store_true')
    parser.add_argument('--expected', type=Path)
    args = parser.parse_args()
    try:
        scenario = json.loads(args.scenario.read_text(encoding='utf-8')); validate_scenario(scenario)
        raw = sys.stdin.buffer.read(4000001)
        if len(raw) > 4000000:
            raise ValueError('trace size bound')
        value = json.loads(raw.decode('utf-8')); validate(value, scenario, args.source)
        if args.expected is not None:
            compare(value, json.loads(args.expected.read_text(encoding='utf-8')), scenario)
    except (ValueError, OSError) as error:
        print('p2p validation: ' + str(error), file=sys.stderr)
        return 2
    print(json.dumps({'complete': True, 'records': len(value['records']), 'packets': len(value['packets'])}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
