#!/usr/bin/env python3
"""Weekly/manual upstream drift reporting with one deduplicated issue per source.

M2 (issue #52) owns the reporting cadence the M1 classifier left open. This
tool resolves each pinned source's latest upstream revision, compares it with
the reviewed pin through `drift.py`, and reports the result on exactly one
ongoing GitHub issue per source, so every observation of a stream lands on
the same thread instead of piling up duplicate issues.

The deduplicated issue is found by the tool's title plus a stable marker in
its body — never by the search API, whose index lags behind writes and cannot
implement read-before-retry — across open and closed issues, so a closed
stream is reopened when a new observation arrives rather than duplicated, and
a repeated observation of an identical state (same path-free report identity
digest) writes nothing at all. Digests are read only from tool-authored,
marker-carried comments authored by this run's reporting identity, so a
foreign comment cannot suppress an observation even with a copied marker;
more than one carrier issue for a stream is a tooling error rather than a
silent split stream.

The reporter only reports. It never rewrites pins.json, never advances a pin,
and never regenerates fixtures: advancing stays the reviewed operator flow
(`drift.py --pins ... --advance` after a full oracle requalification), and the
issue body carries that checklist. Every adapter — revision resolution,
archive download and the GitHub issue client — is injectable, so the suite
exercises the whole flow against fakes before the schedule ever runs it for
real; a fake-driven failure is never a live API surprise. A resolver,
download, binding or issue failure for one source is a tooling error with a
nonzero exit after the remaining sources still report: partial failure is
visible in the per-source results and in the workflow summary, never a silent
no-drift report.

Usage:
    python3 scripts/reference/drift_report.py [--source NAME]... [--latest NAME=SHA]...
        [--pins PATH] [--ledger PATH] [--cache DIR] [--output DIR] [--repo OWNER/REPO]
        [--summary FILE] [--stage | --publish-staged --artifact-url URL]

Exit codes: 0 every source reported or no-op, 1 at least one source failed.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import drift
import fetch
from fetch import digest

ROOT = Path(__file__).resolve().parents[2]
MARKER_PREFIX = 'fortress-drift-report'
REPORT_PREFIX = 'fortress-drift-report-comment'
MAX_COMMENT_BYTES = 65_536
# One pinned upstream tar.gz holds tens of megabytes; anything larger is not a
# candidate archive, so the download refuses instead of filling the disk.
MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
DOWNLOAD_ATTEMPTS = 4
GH_TIMEOUT = 120
REVISION_PATTERN = re.compile(r'[0-9a-f]{40}\Z')
SHA256_PATTERN = re.compile(r'[0-9a-f]{64}\Z')


class ToolingError(Exception):
    pass


def validate_revision(value):
    if not isinstance(value, str) or not REVISION_PATTERN.fullmatch(value):
        raise ToolingError(f'not a 40-hex revision: {value!r}')
    return value


def candidate_root(entry, revision):
    """The archive root of a candidate revision: the pin root's repo stem with the new suffix."""
    stem = entry['root'][:-(len(entry['revision']) + 1)]
    if not stem:
        raise ToolingError(f"pins root does not name the reviewed revision: {entry['root']}")
    return f'{stem}-{revision}'


def extract_archive(archive_path, expected_root, destination):
    """Extract one pinned/candidate archive under its exact root, failing closed on drift."""
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_path) as tar:
        members = tar.getmembers()
        if not members or any(member.name.split('/')[0] != expected_root for member in members):
            raise ToolingError(f'archive root mismatch: expected {expected_root}')
        tar.extractall(destination, filter='data')
    tree = destination / expected_root
    if not tree.is_dir():
        raise ToolingError(f'archive did not contain the expected root directory: {expected_root}')
    return tree


def resolve_latest(entry):
    """The default branch's current commit of the pinned source repository."""
    repository = entry['repository'].removeprefix('https://github.com/')
    try:
        result = subprocess.run(['gh', 'api', f'repos/{repository}/commits/HEAD', '--jq', '.sha'],
                                capture_output=True, encoding='utf-8', timeout=GH_TIMEOUT, check=False)
    except subprocess.TimeoutExpired as error:
        raise ToolingError(f'revision resolution timed out after {GH_TIMEOUT}s: {repository}') from error
    if result.returncode != 0:
        raise ToolingError(f'cannot resolve the latest revision of {repository}: {result.stderr.strip()}')
    return validate_revision(result.stdout.strip())


def download_archive(entry, revision, destination_dir):
    """Fetch the candidate archive and return its path.

    The bytes are bound to the codeload URL over TLS and their sha256 is
    recorded in the observation; proving those bytes are the upstream archive
    happens only when a later fetch verifies the recorded digest (the reviewed
    pin's archive is digest-verified here through `fetch.fetch`).
    """
    url = entry['repository'].replace('https://github.com/', 'https://codeload.github.com/') + '/tar.gz/' + revision
    destination = Path(destination_dir) / f'candidate-{revision}.tar.gz'
    destination.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(DOWNLOAD_ATTEMPTS):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
                temporary = Path(output.name)
                with urllib.request.urlopen(url, timeout=60) as response:
                    received = 0
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        received += len(chunk)
                        if received > MAX_ARCHIVE_BYTES:
                            raise ToolingError(f'candidate archive exceeds {MAX_ARCHIVE_BYTES} bytes: {url}')
                        output.write(chunk)
            temporary.replace(destination)
            return destination
        except ToolingError:
            # The oversized refusal must not leak the partial temp file either.
            if temporary is not None:
                temporary.unlink(missing_ok=True)
            raise
        except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
            if attempt == DOWNLOAD_ATTEMPTS - 1:
                raise ToolingError(f'cannot download {url}: {error}') from error
            time.sleep(2 ** attempt)
    raise ToolingError(f'cannot download {url}')  # pragma: no cover - the loop always returns or raises


class GhIssueClient:
    """The real GitHub issues adapter over authenticated `gh api` calls."""

    def __init__(self, repo):
        self.repo = repo

    def _api(self, args, fields=None):
        payload = None
        if fields is not None:
            args = [*args, '--input', '-']
            payload = json.dumps(fields, ensure_ascii=False)
        try:
            result = subprocess.run(['gh', 'api', *args], input=payload, capture_output=True, encoding='utf-8',
                                    timeout=GH_TIMEOUT, check=False)
        except subprocess.TimeoutExpired as error:
            raise ToolingError(f'gh api timed out after {GH_TIMEOUT}s: {args}') from error
        if result.returncode != 0:
            raise ToolingError(f'gh api failed ({result.returncode}): {result.stderr.strip()}')
        return result.stdout

    def _paged(self, path):
        pages = json.loads(self._api(['--paginate', '--slurp', path]))
        return [item for page in pages for item in page]

    def list_issues(self):
        issues = [item for item in self._paged(f'repos/{self.repo}/issues?state=all&per_page=100')
                  if isinstance(item, dict) and 'pull_request' not in item]
        return [{'number': item['number'], 'state': item['state'], 'title': item.get('title') or '',
                 'body': item.get('body') or ''} for item in issues]

    def create_issue(self, title, body):
        created = json.loads(self._api(['-X', 'POST', f'repos/{self.repo}/issues'],
                                       {'title': title, 'body': body}))
        return created['number']

    def update_issue(self, number, body=None, state=None):
        fields = {key: value for key, value in (('body', body), ('state', state)) if value is not None}
        self._api(['-X', 'PATCH', f'repos/{self.repo}/issues/{number}'], fields)

    def list_comments(self, number):
        return [{'author': (item.get('user') or {}).get('login') or '', 'body': item.get('body') or ''}
                for item in self._paged(f'repos/{self.repo}/issues/{number}/comments?per_page=100')]

    def add_comment(self, number, body):
        self._api(['-X', 'POST', f'repos/{self.repo}/issues/{number}/comments'], {'body': body})

    def current_login(self):
        """The identity this run reports as; digest evidence is trusted only from it."""
        try:
            result = subprocess.run(['gh', 'api', 'user', '--jq', '.login'], capture_output=True,
                                    encoding='utf-8', timeout=GH_TIMEOUT, check=False)
        except subprocess.TimeoutExpired as error:
            raise ToolingError(f'identity resolution timed out after {GH_TIMEOUT}s') from error
        if result.returncode != 0:
            raise ToolingError(f'cannot resolve the reporting identity: {result.stderr.strip()}')
        login = result.stdout.strip()
        if not login:
            raise ToolingError('the reporting identity resolved to an empty login')
        return login


def render_body(source, entry, latest, report_digest, today):
    """The carrier issue body: the stream marker plus the current state and review checklist."""
    return '\n'.join([
        f'<!-- {MARKER_PREFIX}:{source} -->',
        f'# Upstream drift report: {source}',
        '',
        f'- Reviewed pin: `{entry["revision"]}`',
        f'- Latest observed: `{latest}` (on {today})',
        f'- Repository: {entry["repository"]}',
        f'- Latest report digest: `{report_digest}`',
        '',
        'This issue is the single ongoing drift stream for this source. Every weekly or manual '
        'observation appends one comment carrying its `report-digest`; a repeated observation of the '
        'same upstream state comments nothing. The report is evidence, never approval: a pin advances '
        'only through the reviewed operator flow (`scripts/reference/drift.py --pins ... --advance`) '
        'after a full oracle requalification against the candidate and a reviewed `requires_review` list.',
        '',
        'Maintainer checklist:',
        '',
        '- [ ] Classify every `requires_review` path in the latest observation.',
        '- [ ] Rerun the affected upstream scenarios (reviewed vs candidate).',
        '- [ ] Decide: advance the pin, record an intentional divergence, or keep observing.',
        '- [ ] Link the decision to the roadmap and the affected epics.',
    ]) + '\n'


def render_comment(source, entry, latest, report, report_digest, archive_digest, today, artifact_url=None):
    """Keep a readable observation within GitHub's body limit and retain its digest."""
    affected = [f"`{record['path']}`: " + ', '.join(f'`{test}`' for test in record['ledger']['port_test_ids'])
                for record in report['records']
                if isinstance(record['ledger'], dict) and record['ledger'].get('port_test_ids')]
    heading = [
        f'<!-- {REPORT_PREFIX}:{source} -->',
        f'## Observation {today}: `{entry["revision"]}` → `{latest}`',
        '',
        f'report-digest: `{report_digest}`',
        f'candidate archive sha256: `{archive_digest}`',
        '',
    ]
    summary = drift.summarize(report)
    details = [
        '```',
        summary,
        '```',
        '',
        f'Requires review: {", ".join(f"`{path}`" for path in report["requires_review"]) or "none"}.',
        f'Ledger-unmapped paths: {", ".join(f"`{path}`" for path in report["ledger_unmapped"]) or "none"}.',
        f'Affected port tests: {"; ".join(affected) or "none"}.',
    ]
    comment = ('\n'.join(heading + details) + '\n').encode('utf-8', errors='backslashreplace')
    if len(comment) <= MAX_COMMENT_BYTES:
        return comment.decode('utf-8')

    overview = summary.partition('\n')[0]
    receipt = f'Full per-path classification is in `{source}.json` in the reporter output.'
    if artifact_url:
        receipt = f'Full per-path classification is in `{source}.json`. [Download report artifact]({artifact_url})'
    return '\n'.join(heading + [
        overview,
        '',
        f'- Paths requiring review: {len(report["requires_review"])}',
        f'- Ledger-unmapped paths: {len(report["ledger_unmapped"])}',
        '',
        receipt,
        '',
    ])


def comment_digest(comment_body):
    """The `report-digest` recorded in an observation comment, if any."""
    for line in comment_body.splitlines():
        if line.startswith('report-digest: `') and line.endswith('`'):
            return line[len('report-digest: `'):-1]
    return None


def find_carrier(source, issues):
    """Require both stream identifiers and reject duplicate carriers."""
    expected_title = f'Upstream drift report: {source}'
    marker = f'<!-- {MARKER_PREFIX}:{source} -->'
    all_issues = issues.list_issues()
    carriers = [issue for issue in all_issues
                if issue.get('title') == expected_title and marker in issue['body']]
    for issue in all_issues:
        has_marker = marker in issue['body']
        has_title = issue.get('title') == expected_title
        if has_marker != has_title:
            print(f'{source}: issue #{issue["number"]} carries only the '
                  f'{"stream marker" if has_marker else "stream title"} and is not adopted; '
                  'it can fork the stream until it is closed or retitled', file=sys.stderr)
    if len(carriers) > 1:
        raise ToolingError(f'{source}: {len(carriers)} issues carry the drift-report identity '
                           f'({", ".join("#" + str(issue["number"]) for issue in carriers)}); '
                           'remove the marker from or retitle all but one — closing them does '
                           'not help because closed issues are still scanned')
    return carriers[0] if carriers else None


def observation_digest(report):
    # Local extraction paths and later receipt metadata are outside the stable drift identity.
    identity = {key: value for key, value in report.items()
                if key not in ('old_tree', 'new_tree', 'report_digest', 'candidate_archive_sha256')}
    return hashlib.sha256((json.dumps(identity, indent=2, sort_keys=True) + '\n').encode('utf-8')).hexdigest()


def stage_report(source, entry, latest, cache, path, ledger):
    """Classify the verified pin and candidate and write a complete observation receipt."""
    validate_revision(latest)
    reviewed_archive = fetch.fetch(entry['archive'], f'{entry["revision"]}.tar.gz', offline=False, cache=cache)
    with tempfile.TemporaryDirectory(dir=Path(cache)) as work:
        reviewed_tree = extract_archive(reviewed_archive, entry['root'], Path(work) / 'reviewed')
        if latest == entry['revision']:
            return None
        candidate_archive = download_archive(entry, latest, Path(work))
        archive_digest = digest(candidate_archive)
        candidate_tree = extract_archive(candidate_archive, candidate_root(entry, latest), Path(work) / 'candidate')
        report = drift.build_report(source, reviewed_tree, candidate_tree, ledger=ledger,
                                    repository=entry['repository'], old_revision=entry['revision'],
                                    new_revision=latest)
        report['report_digest'] = observation_digest(report)
        report['candidate_archive_sha256'] = archive_digest
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=path.parent) as temporary:
        draft = Path(temporary) / path.name
        draft.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n', encoding='utf-8')
        draft.replace(path)
    return report


def read_staged_report(path, source, entry):
    report = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(report, dict) or (
            report.get('schema_version'), report.get('source'), report.get('repository'), report.get('reviewed_revision')
    ) != (1, source, entry['repository'], entry['revision']):
        raise ToolingError(f'{path.name}: staged report does not match its pinned source')
    archive_digest = report.get('candidate_archive_sha256')
    if (report.get('report_digest') != observation_digest(report)
            or not isinstance(archive_digest, str) or not SHA256_PATTERN.fullmatch(archive_digest)):
        raise ToolingError(f'{path.name}: staged report digest is invalid')
    validate_revision(report.get('candidate_revision'))
    return report


def publish_report(report, entry, issues, carrier, today, identity, artifact_url):
    """Publish one observation unless this identity already recorded its digest."""
    source = report['source']
    latest = report['candidate_revision']
    report_digest = report['report_digest']
    identity = identity if identity is not None else issues.current_login()
    body = render_body(source, entry, latest, report_digest, today)
    number = carrier['number'] if carrier else issues.create_issue(f'Upstream drift report: {source}', body)

    recorded = [comment_digest(item['body']) for item in issues.list_comments(number)
                if f'<!-- {REPORT_PREFIX}:{source} -->' in item['body'] and item.get('author') == identity]
    if report_digest in recorded:
        return 'digest-known', number

    action = 'commented' if carrier else 'created'
    if carrier and carrier['state'] != 'open':
        issues.update_issue(number, state='open')
        action = 'reopened'
    if carrier and carrier['body'] != body:
        issues.update_issue(number, body=body)
    comment = render_comment(source, entry, latest, report, report_digest,
                             report['candidate_archive_sha256'], today, artifact_url)
    issues.add_comment(number, comment)
    return action, number


def main_with_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pins', type=Path, default=ROOT / 'docs/reference/pins.json')
    parser.add_argument('--ledger', type=Path, default=ROOT / 'docs/reference/parity-ledger.json')
    parser.add_argument('--cache', type=Path, default=fetch.CACHE)
    parser.add_argument('--output', type=Path, default=ROOT / '.cache/results/drift-report')
    parser.add_argument('--source', action='append', help='restrict the run to one pinned source (repeatable)')
    parser.add_argument('--latest', action='append', metavar='NAME=SHA',
                        help='observe this revision instead of resolving it (repeatable)')
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY'),
                        help='owner/repo for the issue stream (defaults to GITHUB_REPOSITORY)')
    parser.add_argument('--summary', type=Path, help='append one markdown line per source here')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--stage', action='store_true', help='write JSON reports to a fresh output directory without accessing GitHub issues')
    mode.add_argument('--publish-staged', action='store_true', help='publish existing staged JSON without reclassifying')
    parser.add_argument('--artifact-url', help='uploaded staged JSON for oversized observations')
    parser.add_argument('--reporting-identity', metavar='LOGIN',
                        help='the identity this run reports as; omit to resolve it through `gh api user`. '
                             'The scheduled workflow passes github-actions[bot] because the Actions '
                             'installation token cannot resolve the authenticated user (HTTP 403).')
    args = parser.parse_args(argv)
    if args.summary is not None and args.summary == Path(''):
        # An unset environment variable expands to an empty argument, which
        # Path normalizes to the working directory; treat it as absent instead
        # of appending to a directory after the work is done.
        args.summary = None

    pins = fetch.load_manifest(args.pins)
    overrides = {}
    for pair in args.latest or []:
        name, _, revision = pair.partition('=')
        if name not in pins['sources'] or not revision:
            raise ToolingError(f'--latest must name a pinned source and a revision: {pair}')
        overrides[name] = validate_revision(revision)
    names = args.source or sorted(pins['sources'])
    unknown = [name for name in names if name not in pins['sources']]
    if unknown:
        raise ToolingError(f'pins manifest has no source named: {", ".join(unknown)}')
    if args.publish_staged != bool(args.artifact_url) or (args.publish_staged and overrides):
        raise ToolingError('--publish-staged requires --artifact-url and cannot use --latest')
    if not args.stage and (args.repo is None or not args.repo.strip()):
        raise ToolingError('--repo is required when GITHUB_REPOSITORY is unset')
    if args.reporting_identity is not None and not args.reporting_identity.strip():
        # An empty identity would own no comments, so every run would
        # re-observe: refuse it instead of silently degrading the cadence.
        raise ToolingError('--reporting-identity must name a login when present')
    issues = None if args.stage else GhIssueClient(args.repo)
    if args.stage:
        args.output.mkdir(parents=True)

    ledger = args.ledger if args.ledger.exists() else None
    if ledger is None and not args.publish_staged:
        print(f'parity ledger not found at {args.ledger}: every changed path reports as ledger-unmapped',
              file=sys.stderr)
    today = time.strftime('%Y-%m-%d', time.gmtime())

    results, failures = [], []
    for name in names:
        entry = pins['sources'][name]
        path = args.output / f'{name}.json'
        try:
            if args.publish_staged:
                if not path.exists():
                    continue
                report = read_staged_report(path, name, entry)
                carrier = find_carrier(name, issues)
            else:
                latest = overrides.get(name) or resolve_latest(entry)
                carrier = None if args.stage else find_carrier(name, issues)
                report = stage_report(name, entry, latest, args.cache, path, ledger)
            if report is None:
                results.append({'source': name, 'action': 'noop', 'reason': 'latest is the reviewed pin'})
                print(f'{name}: noop (latest is the reviewed pin)')
                continue
            action, issue = ('staged', None) if args.stage else publish_report(
                report, entry, issues, carrier, today, args.reporting_identity, args.artifact_url)
            result = {'source': name, 'action': action, 'latest': report['candidate_revision'],
                      'requires_review': report['requires_review']}
            results.append(result)
            issue_label = f' issue=#{issue}' if issue is not None else ''
            print(f"{name}: {action} at {result['latest']}{issue_label}"
                  f" drift={report['drift']} requires_review={len(report['requires_review'])}")
        except (ToolingError, ValueError, KeyError, OSError, tarfile.TarError,
                subprocess.SubprocessError) as error:
            failures.append(f'{name}: {error}')
            print(f'{name}: tooling error: {error}', file=sys.stderr)
    if args.publish_staged and not results and not failures:
        raise ToolingError('no staged reports for the selected sources')
    if args.summary is not None:
        lines = (f"- {result['source']}: {result['action']} at `{result.get('latest', 'n/a')}`"
                 f" (requires_review: {len(result.get('requires_review') or [])})"
                 for result in results)
        body = '\n'.join(lines) + '\n'
        if failures:
            body += '\n### Failures\n\n' + '\n'.join(f'- {failure}' for failure in failures) + '\n'
        with args.summary.open('a', encoding='utf-8') as stream:
            stream.write(body)
    if failures:
        print('drift report: tooling errors: ' + '; '.join(failures), file=sys.stderr)
        return 1
    return 0


def main():
    sys.exit(main_with_args(sys.argv[1:]))


if __name__ == '__main__':
    main()
