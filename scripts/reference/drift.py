#!/usr/bin/env python3
"""Classify upstream drift between two pinned source trees, conservatively.

M1 (issue #51) owns drift detection and impact mapping. This tool compares a
last-reviewed tree against a latest-observed tree of one pinned source,
classifies every changed path into the reviewed categories, and maps each path
onto its parity-ledger entry. It never claims semantic equivalence:
token-aware checks only label noise (whitespace/comment-only edits) and narrow
signals (constants, attributes/macros, cfg gates), and every label still
reports a source change that a reviewer must classify before a reviewed pin
advances. Anything the classifier cannot place fails closed as
`requires_review` rather than passing as known. A missing, unreadable or
bounded-out input is a tooling error with a nonzero exit — never a "no drift"
report (issue #51: rewritten history, unreachable baselines and truncated
comparisons must not report no drift).

Usage:
    python3 scripts/reference/drift.py --source fortress --old OLD_TREE --new NEW_TREE
        [--ledger docs/reference/parity-ledger.json] [--report REPORT.json] [--quiet]

Exit codes: 0 completed comparison (drift or not), 1 tooling/input failure.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import sys

# Walk bounds: one pinned upstream tree holds a few thousand files well inside
# these; exceeding them means the input is not a pinned tree, so fail closed.
MAX_FILES = 20000
MAX_FILE_BYTES = 8 * 1024 * 1024

# Category -> the path shapes it owns. First match wins, so the specific
# verification-material shapes come before the broad production-source one.
CATEGORY_RULES = (
    ('tests_models_fixtures', ('tests/', 'specs/', 'benches/', 'examples/', 'fixtures/', 'fuzz/')),
    ('dependencies', ('cargo.toml', 'cargo.lock', 'package.json', 'package-lock.json')),
    ('build_logic', ('build.rs', '.github/', 'makefile', 'justfile')),
    ('documentation', ('.md', '.mdx', '.adoc')),
    ('production_source', ('.rs', '.toml', '.json', '.proto', '.yml', '.yaml')),
)
UNMATCHED = 'requires_review'

COMMENT_PREFIXES = ('//', '///', '//!')
CONST_PREFIXES = ('const ', 'pub const ', 'static ', 'pub static ')
ATTRIBUTE_PREFIXES = ('#[', '#![')
MACRO_PREFIX = 'macro_rules!'
CFG_MARKER = '#[cfg('
# Signal values that name pure formatting or comment churn; every other
# signal routes the path to review.
NOISE_SIGNALS = {'whitespace_or_comment_only'}


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            hasher.update(chunk)
    return hasher.hexdigest()


def inventory(tree):
    """Every file under the tree: relative path -> {sha256, bytes}, bounded."""
    root = Path(tree)
    if not root.is_dir():
        raise ValueError(f'source tree is missing or not a directory: {root}')
    files = {}
    for path in sorted(root.rglob('*')):
        if not path.is_file() or '.git' in path.relative_to(root).parts:
            continue
        if len(files) >= MAX_FILES:
            raise ValueError(f'tree exceeds the {MAX_FILES}-file walk bound: {root}')
        size = path.stat().st_size
        files[path.relative_to(root).as_posix()] = {
            'sha256': digest(path) if size <= MAX_FILE_BYTES else None,
            'bytes': size,
        }
    return files


def _meaningful(lines):
    """Non-comment lines, whitespace-normalized and order-insensitive.

    A trailing comment counts as noise here: the normalized text keeps the
    code and drops everything from the first `//` onward, so a comment added
    behind unchanged code cannot read as a semantic edit.
    """
    kept = []
    for line in lines:
        text = line
        for marker in COMMENT_PREFIXES:
            index = text.find(marker)
            if index >= 0:
                text = text[:index]
        text = ' '.join(text.split())
        if text:
            kept.append(text)
    return sorted(kept)


def _changed_lines(old_lines, new_lines):
    """The added and removed sides of one line-level diff."""
    added, removed = [], []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, old_lines, new_lines).get_opcodes():
        if tag in ('delete', 'replace'):
            removed.extend(old_lines[i1:i2])
        if tag in ('insert', 'replace'):
            added.extend(new_lines[j1:j2])
    return added, removed


def line_signals(old_lines, new_lines):
    """Narrow, conservative signals about what kind of lines differ.

    These labels only inform review; they never upgrade a change to safe. A
    signal list containing `semantic_lines` names real code edits.
    """
    added, removed = _changed_lines(old_lines, new_lines)
    if not added and not removed:
        return []
    stripped = [line.strip() for line in added + removed]
    if all(not line or line.startswith(COMMENT_PREFIXES) for line in stripped):
        return ['whitespace_or_comment_only']
    if _meaningful(old_lines) == _meaningful(new_lines):
        return ['whitespace_or_comment_only']
    signals = []
    if all(line.startswith(CONST_PREFIXES) for line in stripped):
        signals.append('constants_or_statics')
    if all(line.startswith(ATTRIBUTE_PREFIXES) or line.startswith(MACRO_PREFIX) for line in stripped):
        signals.append('attributes_or_macros')
    if any(CFG_MARKER in line for line in stripped):
        signals.append('cfg_gate_touched')
    return signals or ['semantic_lines']


def classify_path(relative):
    """One category for the path, or `requires_review` when nothing matches."""
    lowered = relative.lower()
    for category, shapes in CATEGORY_RULES:
        for shape in shapes:
            if lowered.startswith(shape) or lowered.endswith(shape):
                return category
    return UNMATCHED


def _read_lines(tree, name):
    try:
        return (Path(tree) / name).read_text(encoding='utf-8', errors='replace').splitlines()
    except OSError:
        return None


def classify_change(name, old_tree, new_tree, old_entry, new_entry):
    """One record for one changed path: category, signals, review gate.

    The gate is conservative by construction: every change whose differing
    lines are not pure whitespace/comment noise needs review, whatever its
    category — a constant, an attribute, a documentation edit and an unmatched
    path can all move behavior or evidence, and the classifier cannot prove
    otherwise.
    """
    record = {'path': name, 'kind': 'changed', 'category': classify_path(name), 'signals': [],
              'requires_review': False}
    if record['category'] == UNMATCHED:
        record['requires_review'] = True
    else:
        old_lines = _read_lines(old_tree, name) if old_entry is not None else []
        new_lines = _read_lines(new_tree, name) if new_entry is not None else []
        if old_lines is not None and new_lines is not None:
            record['signals'] = line_signals(old_lines, new_lines)
            if any(signal not in NOISE_SIGNALS for signal in record['signals']):
                record['requires_review'] = True
    return record


def compare(old_tree, new_tree):
    old = inventory(old_tree)
    new = inventory(new_tree)
    changed, added, deleted = [], [], []
    for name in sorted(set(old) | set(new)):
        if name not in old:
            added.append(name)
        elif name not in new:
            deleted.append(name)
        elif old[name]['sha256'] != new[name]['sha256']:
            changed.append(name)
    return {'old': old, 'new': new, 'changed': changed, 'added': added, 'deleted': deleted}


def detect_renames(diff):
    """An added path whose bytes a deleted path still holds is a rename."""
    by_digest = {}
    for name in diff['deleted']:
        entry = diff['old'][name]
        if entry['sha256'] is not None:
            by_digest.setdefault(entry['sha256'], []).append(name)
    renames = []
    for name in diff['added']:
        entry = diff['new'][name]
        matches = by_digest.get(entry['sha256']) if entry['sha256'] is not None else None
        if matches:
            renames.append({'from': matches[0], 'to': name})
    return renames


def build_report(source, old_tree, new_tree, ledger=None):
    """The full machine-readable drift report for one source tree pair."""
    diff = compare(old_tree, new_tree)
    renames = detect_renames(diff)
    renamed_old = {rename['from'] for rename in renames}
    renamed_new = {rename['to'] for rename in renames}
    records = [classify_change(name, old_tree, new_tree, diff['old'][name], diff['new'][name])
               for name in diff['changed']]
    for name in diff['added']:
        if name in renamed_new:
            continue
        record = classify_change(name, old_tree, new_tree, None, diff['new'][name])
        record['kind'] = 'added'
        records.append(record)
    for name in diff['deleted']:
        if name in renamed_old:
            continue
        record = classify_change(name, old_tree, new_tree, diff['old'][name], None)
        record['kind'] = 'deleted'
        records.append(record)
    for rename in renames:
        record = classify_change(rename['to'], old_tree, new_tree, diff['old'][rename['from']],
                                 diff['new'][rename['to']])
        record['kind'] = 'renamed'
        record['rename_from'] = rename['from']
        records.append(record)
    decisions = {}
    if ledger is not None:
        loaded = ledger if isinstance(ledger, dict) else json.loads(Path(ledger).read_text(encoding='utf-8'))
        decisions = loaded.get('decisions', {})
    for record in records:
        entry = decisions.get(f'{source}:{record["path"]}')
        record['ledger'] = ({'status': entry.get('status'), 'applicability': entry.get('applicability'),
                             'port_test_ids': entry.get('port_test_ids', [])}
                            if isinstance(entry, dict) else 'unmapped')
    return {
        'schema_version': 1,
        'source': source,
        'old_tree': str(old_tree),
        'new_tree': str(new_tree),
        'drift': bool(records),
        'files_changed': len(diff['changed']),
        'files_added': len(diff['added']) - len(renamed_new),
        'files_deleted': len(diff['deleted']) - len(renamed_old),
        'files_renamed': len(renames),
        'categories': sorted({record['category'] for record in records}),
        'requires_review': [record['path'] for record in records if record['requires_review']],
        'ledger_unmapped': [record['path'] for record in records if record['ledger'] == 'unmapped'],
        'records': records,
    }


def summarize(report):
    """One human-readable line per changed path plus the counts header."""
    lines = [f"drift: {report['files_changed']} changed, {report['files_added']} added, "
             f"{report['files_deleted']} deleted, {report['files_renamed']} renamed in {report['source']}"]
    for record in report['records']:
        marker = ' REVIEW' if record['requires_review'] else ''
        ledger = record['ledger'] if isinstance(record['ledger'], str) else record['ledger']['status']
        rename = f" (renamed from {record['rename_from']})" if record['kind'] == 'renamed' else ''
        lines.append(f"  [{record['category']}{marker}] {record['path']}{rename} "
                     f"signals={record['signals'] or '-'} ledger={ledger}")
    return '\n'.join(lines)


def main_with_args(argv):
    """Parse `argv`, run one comparison, and return the process exit code."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, help='pins.json source name (fortress, sdk, server)')
    parser.add_argument('--old', required=True, help='last-reviewed source tree')
    parser.add_argument('--new', required=True, help='latest-observed source tree')
    parser.add_argument('--ledger', help='parity-ledger.json for impact mapping')
    parser.add_argument('--report', type=Path, help='write the machine-readable report here')
    parser.add_argument('--quiet', action='store_true', help='print only the counts header')
    args = parser.parse_args(argv)
    try:
        report = build_report(args.source, args.old, args.new, args.ledger)
    except (ValueError, OSError, json.JSONDecodeError) as failure:
        print(f'drift tooling failed: {failure}', file=sys.stderr)
        return 1
    if args.report is not None:
        args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(summarize(report).splitlines()[0] if args.quiet else summarize(report))
    return 0


def main():
    return main_with_args(sys.argv[1:])


if __name__ == '__main__':
    raise SystemExit(main())
