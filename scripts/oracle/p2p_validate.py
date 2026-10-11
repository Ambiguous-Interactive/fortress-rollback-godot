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
    parser.add_argument('--corpus-case')
    args = parser.parse_args()
    try:
        if args.corpus_case is not None and args.expected is None:
            raise ValueError('--corpus-case requires --expected')
        if args.corpus_case is not None:
            from p2p_lifecycle import CORPUS_REQUIREMENTS
            if args.corpus_case not in CORPUS_REQUIREMENTS:
                raise ValueError('unknown corpus case')
        scenario = json.loads(args.scenario.read_text(encoding='utf-8')); validate_scenario(scenario)
        if args.corpus_case is not None and 'lifecycle' not in scenario:
            raise ValueError('--corpus-case requires lifecycle scenario')
        raw = sys.stdin.buffer.read(4000001)
        if len(raw) > 4000000:
            raise ValueError('trace size bound')
        value = json.loads(raw.decode('utf-8')); validate(value, scenario, args.source)
        if args.expected is not None:
            expected = json.loads(args.expected.read_text(encoding='utf-8'))
            compare(value, expected, scenario)
            if args.corpus_case is not None:
                from p2p_lifecycle import corpus_evidence
                from p2p_lifecycle_controls import controls
                corpus_evidence(args.corpus_case, expected, controls(value, expected, scenario))
    except (ValueError, OSError) as error:
        print('p2p validation: ' + str(error), file=sys.stderr)
        return 2
    print(json.dumps({'complete': True, 'records': len(value['records']), 'packets': len(value['packets'])}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
