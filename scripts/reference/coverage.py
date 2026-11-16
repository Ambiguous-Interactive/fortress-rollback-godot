#!/usr/bin/env python3
"""Verify that ledger coverage claims are bound to executed port-test evidence.

Task #55 owns the evidence boundary between source-family discovery and
executable coverage certification. This tool takes the parity ledger and a
result bundle produced by one actual test execution and checks that every
declared supported behavior is backed by a passing, complete result that
executed at the ledger's pinned source revision, on the bundle's declared
engine, with its named artifact present under the given evidence directory and
byte-identical to its recorded digest. A status flag or a nonempty
`port_test_ids` list alone is never coverage: forged identities, stale
revisions, partial completions and missing artifacts fail for their specific
reasons. `semantic_audit_complete` is held to the strict shape: with the flag
set, the verified set must equal the declared supported set exactly — no
unverified supported decision and no result outside it.

Result bundle (schema 1) — produced by the engineer running the port suite:

    {
      "schema_version": 1,
      "source_revision": "<40-hex commit the suite executed at>",
      "ledger_sha256": "<sha256 of the exact parity-ledger.json certified>",
      "run_id": "<opaque identity of the one execution>",
      "engine": "<engine version the declared gate runs on>",
      "results": [{"test_id": "...", "suite": "...", "status": "passed",
                   "complete": true, "engine": "<same gate>", "seed": 1234,
                   "artifact": "<name under the evidence directory>",
                   "artifact_sha256": "<sha256>"}]
    }

`run_id` binds the bundle: it must equal the SHA-256 of the canonical results
array, so editing any result without recomputing the identity fails.

Usage:
    python3 scripts/reference/coverage.py --ledger docs/reference/parity-ledger.json \
        --bundle BUNDLE.json --artifacts EVIDENCE_DIR

Exit codes: 0 every declared coverage claim verified, 1 verification failed
(reasons listed), 2 tooling/input failure.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

SUPPORTED_STATUSES = {'covered'}
SUPPORTED_APPLICABILITY = {'applicable'}


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def load_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def canonical_results_digest(results):
    return digest_bytes(json.dumps(results, sort_keys=True, separators=(',', ':')).encode('utf-8'))


def supported_decisions(ledger):
    """The ledger decisions that claim executable coverage.

    A decision claiming `covered` applicability without any port-test identity
    is malformed for certification purposes and surfaces as a named failure,
    never as silent support.
    """
    supported, malformed = [], []
    for key, decision in ledger.get('decisions', {}).items():
        if not isinstance(decision, dict) or decision.get('status') not in SUPPORTED_STATUSES \
                or decision.get('applicability') not in SUPPORTED_APPLICABILITY:
            continue
        identities = decision.get('port_test_ids') or []
        if identities:
            supported.append((key, identities))
        else:
            malformed.append(key)
    return supported, malformed


def verify(ledger_path, bundle_path, artifacts_dir):
    """Check one bundle against one ledger; return (verified, reasons)."""
    ledger_bytes = Path(ledger_path).read_bytes()
    bundle = load_json(bundle_path)
    if bundle.get('schema_version') != 1:
        raise ValueError('unsupported result bundle schema')
    if not isinstance(bundle.get('run_id'), str) or not bundle['run_id']:
        raise ValueError('result bundle lacks a run identity')
    if bundle.get('results') is None or not isinstance(bundle['results'], list):
        raise ValueError('result bundle lacks a results array')
    reasons = []
    if bundle.get('ledger_sha256') != digest_bytes(ledger_bytes):
        reasons.append('bundle certifies a different parity ledger '
                       f'(expected {digest_bytes(ledger_bytes)}, got {bundle.get("ledger_sha256")})')
    ledger = json.loads(ledger_bytes)
    revision = (ledger.get('inventory', {}).get('source', {}) or {}).get('revision')
    if not revision:
        raise ValueError('parity ledger does not record a pinned source revision')
    if bundle.get('source_revision') != revision:
        reasons.append(f'bundle executed at {bundle.get("source_revision")!r}, '
                       f'ledger pins {revision!r}')
    if canonical_results_digest(bundle['results']) != bundle['run_id']:
        reasons.append('run identity does not match the results array')
    results = {}
    for entry in bundle['results']:
        test_id = entry.get('test_id')
        if not isinstance(test_id, str) or not test_id:
            raise ValueError('result entry without a test identity')
        results.setdefault(test_id, []).append(entry)
    gate_engine = bundle.get('engine')
    if not isinstance(gate_engine, str) or not gate_engine:
        raise ValueError('result bundle lacks a declared engine gate')
    supported, malformed = supported_decisions(ledger)
    for key in malformed:
        reasons.append(f'covered decision without port-test identities: {key}')
    verified = set()
    for key, identities in supported:
        for identity in identities:
            entries = results.get(identity)
            if not entries:
                reasons.append(f'{key}: no executed result for {identity}')
                continue
            passed = [entry for entry in entries
                      if entry.get('status') == 'passed' and entry.get('complete') is True]
            if not passed:
                reasons.append(f'{key}: {identity} never completed with a passing result')
                continue
            entry = passed[0]
            if entry.get('engine') != gate_engine:
                reasons.append(f'{key}: {identity} executed on {entry.get("engine")!r}, '
                               f'gate declares {gate_engine!r}')
                continue
            name, recorded = entry.get('artifact'), entry.get('artifact_sha256')
            if not isinstance(name, str) or not name or not isinstance(recorded, str):
                reasons.append(f'{key}: {identity} lacks artifact evidence')
                continue
            artifact = Path(artifacts_dir) / name
            try:
                actual = digest_bytes(artifact.read_bytes())
            except OSError:
                reasons.append(f'{key}: {identity} cites missing artifact {name}')
                continue
            if actual != recorded:
                reasons.append(f'{key}: {identity} artifact {name} digest drift '
                               f'(recorded {recorded}, actual {actual})')
                continue
            verified.add((key, identity))
    unverified_keys = sorted({key for key, _ in supported} - {key for key, _ in verified})
    if ledger.get('semantic_audit_complete') is True:
        if unverified_keys:
            reasons.append('audit-complete flag set with unverified coverage: ' + ', '.join(unverified_keys))
        claimed = {identity for _, identities in supported for identity in identities}
        for identity in sorted(set(results) - claimed):
            reasons.append(f'audit-complete flag set with results outside the supported set: {identity}')
        decided = {decision.get('status') for decision in ledger.get('decisions', {}).values()
                   if isinstance(decision, dict) and decision.get('status') != 'pending'}
        if not decided:
            reasons.append('audit-complete flag set with an entirely pending ledger')
    elif unverified_keys:
        reasons.append('unverified supported decisions: ' + ', '.join(unverified_keys))
    return not reasons, reasons


def summarize(verified, reasons, supported_count, verified_count):
    header = (f'coverage verified: {verified_count}/{supported_count} supported identities'
              if verified else f'coverage failed with {len(reasons)} reason(s)')
    return '\n'.join([header] + [f'  - {reason}' for reason in reasons])


def main_with_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ledger', required=True, help='parity-ledger.json')
    parser.add_argument('--bundle', required=True, help='the executed result bundle (schema 1)')
    parser.add_argument('--artifacts', required=True, help='directory holding the cited artifacts')
    args = parser.parse_args(argv)
    try:
        verified, reasons = verify(args.ledger, args.bundle, args.artifacts)
    except (ValueError, OSError, json.JSONDecodeError, KeyError) as failure:
        print(f'coverage tooling failed: {failure}', file=sys.stderr)
        return 2
    ledger = load_json(args.ledger)
    supported, _ = supported_decisions(ledger)
    total = sum(len(identities) for _, identities in supported)
    print(summarize(verified, reasons, total, len(supported) and total - len(reasons)))
    return 0 if verified else 1


def main():
    return main_with_args(sys.argv[1:])


if __name__ == '__main__':
    raise SystemExit(main())
