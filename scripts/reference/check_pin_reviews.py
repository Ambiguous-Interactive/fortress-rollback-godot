#!/usr/bin/env python3
"""Verify tracked advancement decisions against the base and candidate archives."""

import argparse
import hashlib
import re
import subprocess
import sys
import tarfile

import drift
import fetch


def verify_advancements(base, candidate, review_dir, ledger, *, offline=False):
    verified = []
    for name, old in base['sources'].items():
        new = candidate['sources'].get(name)
        if new is None:
            continue
        if (new['revision'], new['archive']['digest']) == (old['revision'], old['archive']['digest']):
            continue
        if not re.fullmatch(r'[a-z][a-z0-9_-]*', name):
            raise ValueError(f'invalid source name: {name!r}')
        review = new.get('review', {})
        receipt = review_dir / f'{name}-{new["revision"]}.json'
        if not receipt.is_file():
            raise ValueError(f'{name}: missing advancement report {receipt.name}')
        contents = receipt.read_bytes()
        if review.get('advanced_from') != old['revision'] or review.get('report_sha256') != hashlib.sha256(contents).hexdigest():
            raise ValueError(f'{name}: manifest does not cite the base revision and advancement report digest')
        recorded = drift.parse_review_json(contents)
        if not isinstance(recorded, dict) or 'review_decisions' not in recorded:
            raise ValueError(f'{name}: advancement report has no review decisions')
        previous_archive = drift.reviewed_archive(name, old, offline)
        candidate_archive = drift.reviewed_archive(name, new, offline)
        report = drift.archive_report(name, old, new, previous_archive, candidate_archive, ledger)
        if not report['drift']:
            raise ValueError(f'{name}: advancement requires drift between the reviewed pin and the candidate')
        decisions = {'binding': recorded.get('review_binding'), 'paths': recorded['review_decisions']}
        report['review_decisions'] = drift.review_decisions(decisions, report['review_binding'], report['requires_review'])
        if report != recorded:
            raise ValueError(f'{name}: advancement report differs from the verified archive comparison')
        verified.append(name)
    return verified


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True, help='full Git commit SHA for the candidate base')
    parser.add_argument('--offline', action='store_true', help='require already cached archives')
    args = parser.parse_args()
    try:
        if not re.fullmatch(r'[0-9a-f]{40}', args.base):
            raise ValueError('pin review requires the full base commit SHA')
        path = fetch.MANIFEST.relative_to(fetch.ROOT).as_posix()
        original = subprocess.check_output(['git', 'show', f'{args.base}:{path}'], cwd=fetch.ROOT)
        verified = verify_advancements(fetch.parse_manifest(original), fetch.load_manifest(),
                                       fetch.MANIFEST.parent / 'pin-reviews', fetch.MANIFEST.with_name('parity-ledger.json'),
                                       offline=args.offline)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f'pin review failed: {error}', file=sys.stderr)
        return 1
    print(f'Pin reviews: verified {len(verified)} advancement(s)' + (f' ({", ".join(verified)})' if verified else ''))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
