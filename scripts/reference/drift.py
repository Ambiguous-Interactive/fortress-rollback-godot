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
comparisons must not report no drift). Noise labels also never exempt
indentation-significant formats (`YAML`) or non-text bytes from review: a
re-indent can restructure a mapping and a replaced undecodable byte can
hide a real content change.

Usage:
    python3 scripts/reference/drift.py --source fortress --old OLD_TREE --new NEW_TREE
        [--ledger docs/reference/parity-ledger.json] [--report REPORT.json] [--quiet]
    python3 scripts/reference/drift.py --source fortress --old OLD_TREE --new NEW_TREE \
        --pins docs/reference/pins.json --new-revision <sha40> --archive CANDIDATE.tar.gz \
        --ledger docs/reference/parity-ledger.json --report REPORT.json [--advance]

Pin flows (#51): with `--pins`, `--new-revision` and `--archive`, the tool
binds the compared trees to the archives you supply before any bookkeeping
is written — the candidate archive is digested, extracted and required to
match `--new` byte for byte, and `--old` must byte-match the reviewed pin's
cached archive (`fetch.fetch` offline against the manifest digest), so a
mismatched tree, archive or revision is a tooling error, never a recorded
observation. Supply the codeload archive for the claimed revision: the
recorded candidate digest is proven to be the upstream archive when the
next fetch verifies it. Without `--advance` this only records the
observation under
`sources[name].review` (`observed_revision`, `observed_on`, digests). With
`--advance` it additionally rewrites the pin itself (`revision`, archive URL,
digest and root), records `advanced_from`/`advanced_on`, and stamps every
changed path with a commit link; the pin still merges only after the full
oracle requalification and review of this report.

Exit codes: 0 completed comparison (drift or not), 1 tooling/input failure.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tarfile
import tempfile
from datetime import date

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fetch
from fetch import CACHE, same_tree

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

# Formats whose grammar gives leading whitespace structural meaning: a pure
# re-indent can move mappings between nesting levels or change which lines a
# makefile or its autoconf template treats as recipes, so the whitespace-only
# noise label must never exempt them from review (issue #382 review).
INDENTATION_SIGNIFICANT = ('.yml', '.yaml', 'makefile', 'makefile.in', 'makefile.am', '.mk')

COMMENT_PREFIXES = ('//', '///', '//!')
CONST_PREFIXES = ('const ', 'pub const ', 'static ', 'pub static ')
ATTRIBUTE_PREFIXES = ('#[', '#![')
MACRO_PREFIX = 'macro_rules!'
CFG_MARKER = '#[cfg('
# Signal values that name pure formatting or comment churn; every other
# signal routes the path to review.
NOISE_SIGNALS = {'whitespace_or_comment_only'}

# Sentinel a `_read_lines` side returns when its bytes are not valid UTF-8.
# Replacing undecodable bytes would make different byte sequences compare
# equal after decoding, so binary content must gate instead of diffing.
_NON_TEXT = 'non_text_bytes'


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            hasher.update(chunk)
    return hasher.hexdigest()


def _scan_error(error):
    """Fail the whole walk on a directory-listing failure (issue #382 review).

    os.walk's default silently skips directories it cannot list, so two
    trees with differently-readable directories could compare as equal and
    report no drift. A listing failure is a truncated comparison: raise
    instead, so the comparison exits as a tooling error.
    """
    raise ValueError(f'cannot list source directory: {error.filename}') from error


def inventory(tree):
    """Every file under the tree: relative path -> {sha256, bytes}, bounded.

    The walk prunes `.git` directories during descent and enforces both bounds
    while traversing, so a pathological input fails closed instead of paying
    an unbounded enumeration first. A file past `MAX_FILE_BYTES` and a
    directory that cannot be listed are tooling errors: the first would
    silently turn an oversized-file content change into "unchanged", the
    second could hide whole directories from both inventories, and either
    must never report no drift.
    """
    root = Path(tree)
    if not root.is_dir():
        raise ValueError(f'source tree is missing or not a directory: {root}')
    files = {}
    for folder, directories, names in os.walk(root, onerror=_scan_error):
        directories[:] = sorted(name for name in directories if name != '.git')
        for name in sorted(names):
            if len(files) >= MAX_FILES:
                raise ValueError(f'tree exceeds the {MAX_FILES}-file walk bound: {root}')
            path = Path(folder) / name
            size = path.stat().st_size
            if size > MAX_FILE_BYTES:
                raise ValueError(f'file exceeds the {MAX_FILE_BYTES}-byte input bound: {path}')
            files[path.relative_to(root).as_posix()] = {'sha256': digest(path), 'bytes': size}
    return files


def _code_skeleton(lines):
    """Code lines in source order: blanks and whole-line comments dropped.

    Line interiors stay verbatim — no whitespace collapsing, no comment-tail
    stripping — because without a lexer a `//` inside a string literal or a
    space inside one is indistinguishable from real content, and a noise
    verdict must never swallow a semantic edit. Order is preserved: swapping
    two statements changes behavior even though their multiset is unchanged.
    """
    kept = []
    for line in lines:
        text = line.strip()
        if text and not text.startswith(COMMENT_PREFIXES):
            kept.append(text)
    return kept


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
    signal list containing `semantic_lines` names real code edits, and every
    label except the explicit noise one routes the path to review.
    """
    added, removed = _changed_lines(old_lines, new_lines)
    if not added and not removed:
        return []
    stripped = [line.strip() for line in added + removed]
    if all(not line or line.startswith(COMMENT_PREFIXES) for line in stripped):
        return ['whitespace_or_comment_only']
    if _code_skeleton(old_lines) == _code_skeleton(new_lines):
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
    """File lines, the `_NON_TEXT` marker, or None when the file is absent.

    Decoding is strict: with `errors='replace'` two different byte sequences
    (`FF` and `FE`) both decode to U+FFFD and a real content change could
    diff to nothing, so undecodable content comes back marked instead and
    gates as non-text bytes. Read failures propagate: a file that exists but
    cannot be read is a tooling error, never a silently unclassified change.
    """
    path = Path(tree) / name
    if not path.is_file():
        return None
    try:
        return path.read_bytes().decode('utf-8').splitlines()
    except UnicodeDecodeError:
        return _NON_TEXT


def classify_change(name, old_tree, new_tree, old_entry, new_entry, old_name=None):
    """One record for one changed path: category, signals, review gate.

    The gate is conservative by construction: every change whose differing
    lines are not pure whitespace/comment noise needs review, whatever its
    category — a constant, an attribute, a documentation edit and an unmatched
    path can all move behavior or evidence, and the classifier cannot prove
    otherwise. Indentation-significant formats (`.yml`/`.yaml`) never earn
    the noise exemption, and non-text bytes gate unconditionally. A rename
    gates unconditionally: the path is the ledger key, so moving bytes
    between paths moves the mapping even when the bytes match. Content reads
    use each tree's own path (`old_name` names a rename's source), so a
    renamed file's diff compares the real old bytes.
    """
    record = {'path': name, 'kind': 'changed', 'category': classify_path(name), 'signals': [],
              'requires_review': False}
    if record['category'] == UNMATCHED:
        record['requires_review'] = True
    else:
        old_lines = _read_lines(old_tree, old_name or name) if old_entry is not None else []
        new_lines = _read_lines(new_tree, name) if new_entry is not None else []
        if old_lines is None or new_lines is None:
            # A declared file that cannot be read at classification time is a
            # truncated comparison: gate it instead of passing it silently.
            record['requires_review'] = True
        elif old_lines == _NON_TEXT or new_lines == _NON_TEXT:
            # Non-text bytes cannot diff meaningfully, and different bytes
            # with the same replacement decoding would otherwise classify as
            # no change: gate every undecodable side (issue #382 review). The
            # signal is specific to changed-path records: a same-bytes rename
            # reports `path_moved` instead (and still gates unconditionally),
            # and an unmatched path gates before any decode happens.
            record['signals'] = [_NON_TEXT]
            record['requires_review'] = True
        else:
            record['signals'] = line_signals(old_lines, new_lines)
            if (any(signal not in NOISE_SIGNALS for signal in record['signals'])
                    or (name.lower().endswith(INDENTATION_SIGNIFICANT) and record['signals'])):
                # An indentation-significant format never earns the noise
                # exemption: a re-indent can restructure its mapping, so any
                # signal there routes the path to review.
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
    """An added path whose bytes a deleted path still holds is a rename.

    Each deleted candidate is consumed when paired, so two added copies of one
    deleted file report one rename and one addition, never two renames.
    """
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
            renames.append({'from': matches.pop(0), 'to': name})
    return renames


def build_report(source, old_tree, new_tree, ledger=None, repository=None,
                 old_revision=None, new_revision=None):
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
                                 diff['new'][rename['to']], old_name=rename['from'])
        record['kind'] = 'renamed'
        record['rename_from'] = rename['from']
        record['requires_review'] = True
        record['signals'] = ['path_moved']
        records.append(record)
    decisions = {}
    if ledger is not None:
        loaded = ledger if isinstance(ledger, dict) else json.loads(Path(ledger).read_text(encoding='utf-8'))
        decisions = loaded.get('decisions', {})
    commit_base = None
    if repository is not None and new_revision is not None and old_revision is not None:
        if not repository.startswith('https://github.com/'):
            raise ValueError(f'cannot derive commit links for repository: {repository}')
        commit_base = f'{repository}/blob/{new_revision}/'
        reviewed_base = f'{repository}/blob/{old_revision}/'
    for record in records:
        entry = decisions.get(f'{source}:{record["path"]}')
        record['ledger'] = ({'status': entry.get('status'), 'applicability': entry.get('applicability'),
                             'port_test_ids': entry.get('port_test_ids', [])}
                            if isinstance(entry, dict) else 'unmapped')
        if commit_base is not None:
            # A deleted path exists only at the reviewed revision; every other
            # record names its candidate-revision bytes.
            record['url'] = (reviewed_base if record['kind'] == 'deleted' else commit_base) + record['path']
    report = {
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
    if repository is not None:
        report['repository'] = repository
    if old_revision is not None:
        report['reviewed_revision'] = old_revision
        report['reviewed_url'] = f'{repository}/tree/{old_revision}'
    if new_revision is not None:
        report['candidate_revision'] = new_revision
        report['candidate_url'] = f'{repository}/tree/{new_revision}'
    return report


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


def verify_reviewed_tree(entry, old_tree, cache=None):
    """Require `old_tree` to be the pinned extraction of the reviewed archive.

    The report's `reviewed_revision` is trusted only when the compared old
    tree byte-matches the reviewed archive the manifest pins: the archive is
    taken from the local fetch cache (`fetch.fetch` offline, so no network
    runs here and a cold cache refuses with a named error telling the
    operator to fetch first), digested against the manifest's recorded
    digest, extracted and required to equal `--old` byte for byte. Any other
    tree — including a second copy of the candidate — fails closed before
    the comparison runs.
    """
    cache = CACHE if cache is None else cache
    archive = fetch.fetch(entry['archive'], f'{entry["revision"]}.tar.gz', offline=True, cache=cache)
    expected_root = entry['root']
    reviewed_digest = digest(archive)
    with tempfile.TemporaryDirectory(dir=Path(cache)) as temporary:
        with tarfile.open(archive) as tar:
            members = tar.getmembers()
            if not members or any(member.name.split('/')[0] != expected_root for member in members):
                raise ValueError(f'reviewed archive root mismatch: expected {expected_root}')
            tar.extractall(temporary, filter='data')
        if not same_tree(Path(temporary) / expected_root, Path(old_tree)):
            raise ValueError(f'--old is not the reviewed pin extraction: {old_tree}; '
                             'run scripts/reference/fetch.py and pass its extraction')
    return reviewed_digest


def candidate_tree(archive_path, expected_root, tree, cache=None):
    """Digest and extract the candidate archive; require it to be the compared tree.

    The extraction binds the compared tree to the archive the operator
    supplied — its digest, extraction and byte identity — not to the upstream
    archive at the claimed revision. `update_pins` records the supplied
    digest beside the canonical codeload URL, and the next fetch of that URL
    (the Reference Baseline requalification on the advancement PR) verifies
    the real upstream bytes against it, failing closed on a mismatch before
    the pin can merge. The extraction is the only accepted identity proof
    between the claimed revision and the compared tree: the archive's every
    member must live under `expected_root`, and the extracted bytes must
    equal `tree` byte for byte, so a mismatched, truncated or root-drifted
    candidate fails closed before any bookkeeping is recorded. Returns the
    verified archive digest.
    """
    archive = Path(archive_path)
    archive_digest = digest(archive)
    cache = CACHE if cache is None else Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cache) as temporary:
        with tarfile.open(archive) as tar:
            members = tar.getmembers()
            if not members or any(member.name.split('/')[0] != expected_root for member in members):
                raise ValueError(f'candidate archive root mismatch: expected {expected_root}')
            tar.extractall(temporary, filter='data')
        if not same_tree(Path(temporary) / expected_root, Path(tree)):
            raise ValueError(f'observed tree does not match the candidate archive: {tree}')
    return archive_digest


def update_pins(pins_path, source_name, new_revision, archive_digest, report_digest,
                advance, today):
    """Record the observation under `sources[name].review`, optionally advancing the pin.

    The pins file is rewritten atomically only after every value validates; a
    failure anywhere leaves it untouched (fail-closed bookkeeping). Advancing
    without a completed comparison is impossible: callers write the report
    first and pass its digest here.
    """
    pins = Path(pins_path)
    data = json.loads(pins.read_text(encoding='utf-8'))
    sources = data.get('sources', {})
    if source_name not in sources:
        raise ValueError(f'pins manifest has no source named: {source_name}')
    entry = sources[source_name]
    old_revision = entry.get('revision')
    review = entry.setdefault('review', {})
    review['observed_revision'] = new_revision
    review['observed_on'] = today
    review['report_sha256'] = report_digest
    review['archive_sha256'] = archive_digest
    if advance:
        if not entry['repository'].startswith('https://github.com/'):
            raise ValueError(f'cannot derive an archive URL for repository: {entry["repository"]}')
        root = entry.get('root', '')
        if not root.endswith('-' + old_revision):
            raise ValueError(f'pins root does not name the reviewed revision: {root}')
        entry['revision'] = new_revision
        entry['archive'] = {
            'url': entry['repository'].replace('https://github.com/', 'https://codeload.github.com/')
            + '/tar.gz/' + new_revision,
            'digest': archive_digest,
            'algorithm': 'sha256',
        }
        entry['root'] = root[:-(len(old_revision) + 1)] + '-' + new_revision
        review['advanced_from'] = old_revision
        review['advanced_on'] = today
    temporary = pins.with_name(pins.name + '.tmp')
    try:
        temporary.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
        temporary.replace(pins)
    finally:
        temporary.unlink(missing_ok=True)


def main_with_args(argv):
    """Parse `argv`, run one comparison, and return the process exit code."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, help='pins.json source name (fortress, sdk, server)')
    parser.add_argument('--old', required=True, help='last-reviewed source tree')
    parser.add_argument('--new', required=True, help='latest-observed source tree')
    parser.add_argument('--ledger', help='parity-ledger.json for impact mapping')
    parser.add_argument('--report', type=Path, help='write the machine-readable report here')
    parser.add_argument('--quiet', action='store_true', help='print only the counts header')
    parser.add_argument('--pins', help='pins.json for observation bookkeeping or advancement')
    parser.add_argument('--new-revision', help='the candidate revision the observed tree claims to be')
    parser.add_argument('--archive', help='the candidate archive (tar.gz); its digest pins the tree identity')
    parser.add_argument('--advance', action='store_true', help='rewrite the pin, not only record the observation')
    args = parser.parse_args(argv)
    pin_flow = any(flag is not None for flag in (args.pins, args.new_revision, args.archive))
    if pin_flow and (args.pins is None or args.new_revision is None or args.archive is None
                     or args.report is None):
        print('drift tooling failed: the pin flow needs --pins, --new-revision, --archive '
              'and --report together (--advance rewrites the pin; without it only the '
              'observation is recorded)', file=sys.stderr)
        return 1
    if args.advance and not pin_flow:
        print('drift tooling failed: --advance needs --pins, --new-revision, --archive '
              'and --report; alone it would silently do nothing', file=sys.stderr)
        return 1
    try:
        if args.new_revision is not None and re.fullmatch(r'[0-9a-f]{40}', args.new_revision) is None:
            raise ValueError(f'candidate revision is not a 40-hex sha: {args.new_revision}')
        repository = old_revision = expected_root = None
        if pin_flow:
            pins = json.loads(Path(args.pins).read_text(encoding='utf-8'))
            entry = pins.get('sources', {}).get(args.source)
            if not isinstance(entry, dict):
                raise ValueError(f'pins manifest has no source named: {args.source}')
            repository = entry.get('repository')
            old_revision = entry.get('revision')
            root = entry.get('root', '')
            if not root.endswith('-' + str(old_revision)):
                raise ValueError(f'pins root does not name the reviewed revision: {root}')
            if args.advance and (not isinstance(repository, str)
                                 or not repository.startswith('https://github.com/')):
                raise ValueError(f'cannot derive an archive URL for repository: {repository}')
            expected_root = root[:-(len(old_revision) + 1)] + '-' + args.new_revision
        report = build_report(args.source, args.old, args.new, args.ledger,
                              repository=repository, old_revision=old_revision,
                              new_revision=args.new_revision)
        if args.advance and not report['drift']:
            # An advancement's review evidence is the A-to-B drift itself: two
            # identical trees produce a clean report no matter what the trees
            # are, so a B-versus-B submission can never justify rewriting the pin.
            raise ValueError('the compared trees are identical; an advancement '
                             'requires drift between the reviewed pin and the candidate')
        report_digest = None
        if pin_flow:
            if args.report.is_dir():
                raise ValueError(f'the report destination is a directory: {args.report}')
            verify_reviewed_tree(entry, args.old)
            archive_digest = candidate_tree(args.archive, expected_root, args.new)
            report_bytes = json.dumps(report, indent=2).encode('utf-8') + b'\n'
            report_digest = hashlib.sha256(report_bytes).hexdigest()
            # The report installs before the pins commit: after staging, the
            # only failure left is the bookkeeping itself, so every failure
            # leaves the pin untouched — never an advanced revision whose
            # recorded report digest names bytes that never landed (a report
            # left over by a later failure is inert evidence, not bookkeeping).
            staged = args.report.with_name(args.report.name + '.tmp')
            try:
                staged.write_bytes(report_bytes)
                staged.replace(args.report)
                update_pins(args.pins, args.source, args.new_revision, archive_digest,
                            report_digest, args.advance, date.today().isoformat())
            finally:
                staged.unlink(missing_ok=True)
        else:
            if args.report is not None:
                args.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    except (ValueError, OSError, json.JSONDecodeError, KeyError, TypeError, AttributeError) as failure:
        print(f'drift tooling failed: {failure}', file=sys.stderr)
        return 1
    print(summarize(report).splitlines()[0] if args.quiet else summarize(report))
    if pin_flow:
        if report['requires_review']:
            print(f"review gate: {len(report['requires_review'])} path(s) require review before this "
                  f"{'advancement' if args.advance else 'observation'} merges")
        if args.advance:
            print('advancement recorded: merge only after a full oracle requalification '
                  'run against the new pin (Reference Baseline) and review of the report')
    return 0


def main():
    return main_with_args(sys.argv[1:])


if __name__ == '__main__':
    raise SystemExit(main())
