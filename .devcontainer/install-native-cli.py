#!/usr/bin/env python3
"""Install one latest wrapper after its matching Linux release is published."""
import argparse
import codecs
from collections import deque
import json
import math
import os
from pathlib import Path
import re
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


class PublicationPending(Exception):
    """A known native dependency is not fully published yet."""


QUERY_CREDENTIALS = re.compile(r'(https?://[^\s?#]+)\?[^\s]*')
NPM_ERROR = re.compile(r'npm (?:ERR!|error) code ([A-Z0-9_]+)')
PACKAGE_VERSION = re.compile(r'(?<![A-Za-z0-9_@/.+-])(@[a-z0-9._-]+/[a-z0-9._-]+@[0-9A-Za-z.+_-]+)(?![A-Za-z0-9_@/.+-])')
PUBLICATION_ERRORS = {'ETARGET', 'E404'}
SAFE_NPM_ERRORS = PUBLICATION_ERRORS | {'E401', 'EACCES'}
PHASE_UNKNOWN = 'no registry or wrapper postinstall evidence observed'
PHASE_REGISTRY = 'registry activity observed; wrapper postinstall start unobserved'
PHASE_POSTINSTALL = 'wrapper postinstall started; completion unobserved'
PHASE_POSTINSTALL_DONE = 'wrapper postinstall completed; subsequent phase unclassified'
LIFECYCLE_RECORDS = (PHASE_POSTINSTALL, PHASE_POSTINSTALL_DONE)
JOURNAL_FULL = '...[journal truncated at the byte budget]'
HTTP_STATUS = r'[1-5][0-9]{2}|\(status unreported\)'
ERROR_CODE = '|'.join(sorted(SAFE_NPM_ERRORS))
SAFE_JOURNAL_RECORD = re.compile('|'.join((
    f'npm HTTP GET (?:{HTTP_STATUS}); (?:' + '|'.join((PHASE_REGISTRY, *LIFECYCLE_RECORDS)) + ')',
    *LIFECYCLE_RECORDS,
    f'npm error code (?:{ERROR_CODE})(?:, (?:{ERROR_CODE})){{0,3}}',
    r'npm error \(details omitted\)',
    re.escape(JOURNAL_FULL),
)))


# One install's npm http log stays far below this; the cap bounds a pathological
# loop and each single line, so a stuck build cannot fill the disk with evidence.
JOURNAL_LIMIT_BYTES = 4 * 1024 * 1024
# Oversized lines are discarded through the next newline so a credential
# split across reads cannot be mistaken for another npm record.
PENDING_LIMIT_BYTES = 1024 * 1024
# The failure diagnostic prints at most this many journal tail lines and at
# most this many journal tail bytes: a stalled or killed CI context cannot read
# the fixed journal path after the process is gone, so the tail itself must
# reach the job log (issue #249) without one huge line or a pathological
# journal flooding it. The backward read never loads more than this much of
# the file, so a planted oversized file cannot exhaust memory either.
JOURNAL_TAIL_LINES = 40
JOURNAL_TAIL_BYTES = 16384
JOURNAL_TAIL_READ_BYTES = 262144


def redact_query_strings(text):
    """Strip query strings from diagnostic URLs, keeping host and path.

    A configured registry can hand out signed download redirects, and the http
    loglevel prints those URLs. The credentials live in the query, so failure
    and timeout diagnostics never print one.
    """
    return QUERY_CREDENTIALS.sub(r'\1?<redacted>', text)


def journal_path(package):
    """The fixed per-package evidence file for the merged install stream.

    The name must be derivable without the installer process: a Docker or CI
    deadline can kill the installer mid-command, and the next reader has to
    find the partial acquisition-versus-lifecycle evidence on disk (issue #249).
    One host runs one installer per package (one container build per runner), so
    the fixed name has no concurrent writer; a hostile or stale file at the path
    disables journaling instead of breaking the install.
    """
    slug = package.removeprefix('@').replace('/', '-')
    return Path(tempfile.gettempdir()) / f'install-native-cli-{slug}-evidence-v1.log'


def _open_journal(path):
    """Create or truncate the journal safely, or report why journaling is off.

    O_NOFOLLOW refuses a planted symlink, 0600 keeps other users out, and an
    unwritable or foreign-owned path must never turn the diagnostic feature
    into a new install failure, so the caller proceeds without a journal.
    """
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
                raise OSError('journal path must be a regular file owned by the installer')
            os.fchmod(descriptor, 0o600)
            os.ftruncate(descriptor, 0)
            return os.fdopen(descriptor, 'wb'), None
        except OSError:
            os.close(descriptor)
            raise
    except OSError as failure:
        return None, failure


def journal_tail(package):
    """Read a bounded tail containing only the installed safe record vocabulary."""
    path = journal_path(package)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as source:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                return []
            start = source.seek(0, os.SEEK_END) - JOURNAL_TAIL_READ_BYTES
            partial = start > 0
            source.seek(max(0, start))
            data = source.read(JOURNAL_TAIL_READ_BYTES)
    except OSError:
        return []
    lines = data.decode('utf-8', errors='replace').split('\n')
    if partial:
        # A backward cut may begin in the middle of a record.
        lines = lines[1:]
    lines = [line for line in lines if SAFE_JOURNAL_RECORD.fullmatch(line)]
    if not lines:
        return []
    tail = lines[-JOURNAL_TAIL_LINES:]
    if partial or len(lines) > JOURNAL_TAIL_LINES:
        tail.insert(0, f'...[journal head truncated; showing the last {len(tail)} lines]')
    # Accepted records and generated markers contain only ASCII.
    encoded = [(line, len(line) + 1) for line in tail]
    tail_marker = f'...[journal tail truncated at the {JOURNAL_TAIL_BYTES}-byte diagnostic budget]'
    kept = []
    remaining = JOURNAL_TAIL_BYTES
    for line, size in reversed(encoded):
        if size > remaining:
            break
        kept.append(line)
        remaining -= size
    if len(kept) < len(tail):
        # The marker is part of the printed diagnostic, so its bytes come out
        # of the same budget: lines are dropped from the oldest end until the
        # marker fits, and the cut always names itself within the budget.
        marker_size = len(tail_marker.encode('utf-8')) + 1
        while kept and remaining < marker_size:
            remaining += encoded[len(encoded) - len(kept)][1]
            kept.pop()
        kept.append(tail_marker)
    return list(reversed(kept))


class InstallEvidence:
    """Extract bounded diagnostics without retaining registry URLs or script output."""

    def __init__(self, wrapper, publication_specs):
        self.wrapper = wrapper
        self.publication_specs = publication_specs
        self.registry = False
        self.postinstall_started = False
        self.postinstall_completed = False
        self.publication_error = False
        self.other_error = False
        self.missing_spec = False
        self.incomplete = False
        self.recent = deque(maxlen=JOURNAL_TAIL_LINES)

    def summary(self):
        if self.postinstall_completed:
            return PHASE_POSTINSTALL_DONE
        if self.postinstall_started:
            return PHASE_POSTINSTALL
        if self.registry:
            return PHASE_REGISTRY
        return PHASE_UNKNOWN

    def observe(self, line, complete=True):
        if len(line) > PENDING_LIMIT_BYTES:
            self.incomplete = True
            return None
        evidence = self._extract(line.rstrip('\r\n'), complete)
        if evidence:
            self.recent.append(evidence)
        return evidence

    def _extract(self, line, complete):
        # Publication matching stays independent of rendering. Only fixed error
        # codes and a match against the frozen dependency set can leave here.
        diagnostic = redact_query_strings(line)
        errors = set(NPM_ERROR.findall(diagnostic))
        self.publication_error |= bool(errors & PUBLICATION_ERRORS)
        self.other_error |= bool(errors - PUBLICATION_ERRORS)
        self.missing_spec |= any(match.removesuffix('.') in self.publication_specs
                                 for match in PACKAGE_VERSION.findall(diagnostic))
        marker = f'npm info run {self.wrapper} postinstall '
        if complete and self.wrapper and line.startswith(marker):
            payload = line[len(marker):]
            if re.fullmatch(r"\{ code: (?:-?[0-9]+|null), signal: (?:null|'SIG[A-Z0-9]+') \}", payload):
                self.postinstall_completed = True
                return self.summary()
            if re.fullmatch(r'[^\s{]+ +\S.*', payload):
                self.postinstall_started = True
                return self.summary()

        fetch = re.match(r'^npm http fetch GET (?:([1-5][0-9]{2}) )?https?://', line)
        if fetch:
            self.registry = True
            return f'npm HTTP GET {fetch[1] or "(status unreported)"}; {self.summary()}'
        if errors:
            safe = sorted(errors & SAFE_NPM_ERRORS)
            return 'npm error code ' + ', '.join(safe) if safe else 'npm error (details omitted)'
        return None

    def print_summary(self):
        print(f'install phase evidence: {self.summary()}', file=sys.stderr, flush=True)


class Installer:
    def __init__(self, args):
        self.args = args
        self.deadline = time.monotonic() + args.timeout
        # Whether the merged install stream actually opened its evidence journal;
        # the failure diagnostics may only name the path when it did.
        self._journaled = False

    @staticmethod
    def _stream_fileno(process):
        """The raw descriptor of a real merged pipe, or None for buffered collection."""
        try:
            return process.stdout.fileno()
        except (AttributeError, OSError, ValueError):
            return None

    def _stream_with_journal(self, process, fileno, budget, evidence):
        """Flush safe records as npm produces them, including before an outer kill."""
        path = journal_path(self.args.package)
        journal, failure = _open_journal(path)
        self._journaled = journal is not None
        if journal is None:
            print(f'install evidence journal disabled ({failure}); continuing without it',
                  file=sys.stderr, flush=True)
        else:
            print(f'install phase evidence journal: {path}', file=sys.stderr, flush=True)
        decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        pending = ''
        dropping = False
        written = 0
        pending_lifecycle = set(LIFECYCLE_RECORDS)
        marker = (JOURNAL_FULL + '\n').encode('ascii')
        reserve = sum(len(record) + 1 for record in pending_lifecycle)
        general_full = False

        def record(line, complete=True):
            nonlocal written, reserve, general_full
            safe = evidence.observe(line, complete)
            if safe is None or journal is None or written < 0:
                return
            data = (safe + '\n').encode('ascii')
            if safe in LIFECYCLE_RECORDS:
                if safe not in pending_lifecycle:
                    return
                pending_lifecycle.remove(safe)
                reserve -= len(data)
            else:
                if general_full:
                    return
                # Keep space for each lifecycle transition even if HTTP fills
                # the regular budget before the wrapper starts.
                general_full = written + len(data) + len(marker) + reserve > JOURNAL_LIMIT_BYTES
                if general_full:
                    data = marker
            if written + len(data) > JOURNAL_LIMIT_BYTES:
                return
            try:
                journal.write(data)
                journal.flush()
                written += len(data)
            except OSError as breakdown:
                print(f'install evidence journal write failed ({breakdown}); continuing without it',
                      file=sys.stderr, flush=True)
                written = -1

        deadline = time.monotonic() + budget
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    if pending and not dropping:
                        record(pending, complete=False)
                    raise subprocess.TimeoutExpired(process.args, budget)
                ready, _, _ = select.select([fileno], [], [], min(left, 0.5))
                if not ready:
                    continue
                chunk = os.read(fileno, 65536)
                if not chunk:
                    if not dropping:
                        record(pending + decoder.decode(b'', final=True), complete=False)
                    break
                lines = (pending + decoder.decode(chunk, final=False)).split('\n')
                pending = lines.pop()
                for line in lines:
                    if not dropping:
                        record(line)
                    dropping = False
                if dropping or len(pending) > PENDING_LIMIT_BYTES:
                    evidence.incomplete = True
                    dropping = True
                    pending = ''
        finally:
            if journal is not None:
                try:
                    journal.close()
                except OSError as breakdown:
                    print(f'install evidence journal close failed ({breakdown}); continuing without it',
                          file=sys.stderr, flush=True)
        process.wait(timeout=max(0.1, min(10, deadline - time.monotonic())))

    def _print_journal_tail(self, merged):
        """Print the retained journal's tail where the retention note is printed.

        A disabled journal's path can hold planted foreign content, so only a
        journal this run actually opened may be named, and its tail is never a
        new failure: an unreadable file simply prints nothing.
        """
        if not (merged and self._journaled):
            return
        tail = journal_tail(self.args.package)
        if tail:
            print('retained install journal tail:', file=sys.stderr, flush=True)
            for line in tail:
                print(line, file=sys.stderr, flush=True)

    def command(self, command, publication=False, *, phase, merged=False, archive=None, wrapper=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            if merged and self._journaled:
                # The total deadline can expire between commands; the journal of
                # the last failed install still holds its evidence, so this path
                # reports the same tail-plus-retention shape as any other (issue
                # #249 review).
                self._print_journal_tail(True)
                note = f'; partial output retained at {journal_path(self.args.package)}'
            else:
                note = ''
            raise ValueError(f'publication retry budget exhausted before {phase} (elapsed time){note}')
        # The install phase merges the streams so the failure and timeout
        # diagnostics keep npm's original interleaving of lifecycle banners
        # (stdout) and registry logs (stderr). The JSON metadata lookups keep
        # separate streams: merged warnings would corrupt their parsing.
        stdout = subprocess.PIPE
        stderr = subprocess.STDOUT if merged else subprocess.PIPE
        # A new session lets the timeout below end the whole npm process group:
        # the wrapper's postinstall spawns its own children, and any survivor
        # would keep the pipes open, so the partial evidence never reached the
        # TimeoutExpired diagnostic and the hang moved into Python itself.
        process = subprocess.Popen(command, encoding='utf-8', stdout=stdout, stderr=stderr,
                                   start_new_session=True)
        evidence = InstallEvidence(wrapper, publication or ()) if merged else None
        fileno = self._stream_fileno(process) if merged else None
        try:
            if fileno is not None:
                self._stream_with_journal(process, fileno, min(120, remaining), evidence)
                stdout, stderr = '', ''
            else:
                stdout, stderr = process.communicate(timeout=min(120, remaining))
        except subprocess.TimeoutExpired as failure:
            # Preserve the first attempt's diagnostics even when the process tree
            # hangs, in the order npm produced them, without registry credentials.
            # start_new_session made the group id equal the child's pid, and the
            # group may already be gone, which must not replace this diagnostic.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if fileno is not None:
                # The observer already persisted the bytes read before the deadline.
                # Close the pipe rather than collecting a surviving writer's output.
                process.stdout.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            elif merged:
                early = failure.output or ''
                if isinstance(early, bytes):
                    early = early.decode('utf-8', errors='replace')
                for line in early.splitlines():
                    evidence.observe(line)
            else:
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    try:
                        stdout, stderr = process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.stdout.close()
                        if process.stderr:
                            process.stderr.close()
                        stdout, stderr = '', ''
                early = failure.output or ''
                if isinstance(early, bytes):
                    early = early.decode('utf-8', errors='replace')
                print(redact_query_strings(early + (stdout or '') + (stderr or '')), end='', file=sys.stderr)
            if merged:
                evidence.print_summary()
                if not self._journaled:
                    for record in evidence.recent:
                        print(record, file=sys.stderr)
            # Only a journal this run actually opened may be named as retention;
            # a disabled journal's path can hold planted foreign content.
            if merged and self._journaled:
                self._print_journal_tail(merged)
                note = f'; partial output retained at {journal_path(self.args.package)}'
            else:
                note = ''
            raise ValueError(f'CLI installation command timed out during {phase} within publication retry budget{note}') from failure
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        if result.returncode:
            raw = (result.stdout or '') + (result.stderr or '')
            if merged:
                for line in raw.splitlines():
                    evidence.observe(line)
                evidence.print_summary()
                retry = evidence.missing_spec and evidence.publication_error and not (evidence.other_error or evidence.incomplete)
                if retry or not self._journaled:
                    for record in evidence.recent:
                        print(record, file=sys.stderr)
                if retry:
                    raise PublicationPending('matching native dependency during install')
            else:
                combined = redact_query_strings(raw)
                print(combined, end='', file=sys.stderr)
                codes = set(NPM_ERROR.findall(combined))
                missing = publication is True
                if archive is not None:
                    requests = re.findall(r'(?m)^npm (?:ERR!|error) 404 .*? - GET (https?://\S+)(?:[ \t]+- .*)?[ \t]*$', raw)
                    missing = archive in requests
                if missing and codes and codes <= PUBLICATION_ERRORS:
                    raise PublicationPending(phase)
            if merged and self._journaled:
                self._print_journal_tail(merged)
                note = f'; partial output retained at {journal_path(self.args.package)}'
            else:
                note = ''
            raise ValueError(f'CLI installation command failed during {phase} (exit {result.returncode}){note}')
        if merged and self._journaled:
            # A healthy install removes the evidence journal it created. Only
            # the merged install may remove it: a later successful metadata
            # lookup must not delete the previous failed attempt's evidence
            # while publication retries are still running (issue #249 review).
            journal_path(self.args.package).unlink(missing_ok=True)
        return result.stdout.strip()

    def metadata(self, spec, publication=False):
        phase = f'native metadata for {spec}' if publication else 'wrapper metadata'
        return json.loads(self.command(['npm', 'view', spec, '--json', '--prefer-online'], publication, phase=phase))

    def install(self):
        package, arch = self.args.package, {'amd64': 'x64', 'arm64': 'arm64'}[self.args.arch]
        metadata = self.metadata(package + '@latest')
        version = metadata.get('version') if isinstance(metadata, dict) else None
        if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
            raise ValueError('latest wrapper metadata has no exact version')
        if package == '@opencode/cli' and not version.startswith('2.'):
            raise ValueError(f'expected OpenCode v2, got {version}')
        print(f'selected latest {package}@{version} for linux-{arch}', flush=True)
        dependencies = metadata.get('optionalDependencies')
        prefix = '@opencode/cli-linux-' if package == '@opencode/cli' else '@openai/codex-linux-'
        names = [prefix + arch]
        if package == '@opencode/cli' and arch == 'x64':
            names.append(prefix + 'x64-baseline')
        specs = []
        for name in names:
            expected = version if package == '@opencode/cli' else 'npm:@openai/codex@' + version + '-linux-' + arch
            if not isinstance(dependencies, dict) or dependencies.get(name) != expected:
                raise ValueError(f'unsupported matching native dependency metadata: {name}')
            specs.append(name + '@' + version if package == '@opencode/cli' else expected.removeprefix('npm:'))
        # npm can resolve optional dependencies for other platforms before checking their os/cpu fields.
        install_specs = []
        pattern = (r'@opencode/cli-(?:linux|darwin|windows)-(?:x64|arm64)(?:-baseline)?(?:-musl)?'
                   if package == '@opencode/cli' else r'@openai/codex-(linux|darwin|win32)-(x64|arm64)')
        for name, target in dependencies.items():
            match = re.fullmatch(pattern, name)
            if not match:
                continue
            expected = version if package == '@opencode/cli' else f'npm:@openai/codex@{version}-{match[1]}-{match[2]}'
            if target != expected:
                raise ValueError(f'unsupported matching native dependency metadata: {name}')
            install_specs.append(name + '@' + version if package == '@opencode/cli' else target.removeprefix('npm:'))
        for attempt in range(1, self.args.attempts + 1):
            try:
                for spec in specs:
                    native = self.metadata(spec, publication=True)
                    if not isinstance(native, dict) or native.get('version') != spec.rsplit('@', 1)[1]:
                        raise ValueError(f'native package metadata does not match selected version: {spec}')
                    dist = native.get('dist')
                    archive = dist.get('tarball') if isinstance(dist, dict) else None
                    parsed = urlsplit(archive) if isinstance(archive, str) else None
                    if not parsed or parsed.scheme not in ('http', 'https') or not parsed.hostname or not parsed.path:
                        raise ValueError(f'invalid native archive metadata: {spec}')
                    # npm can return success after silently discarding a missing optional archive.
                    self.command(['npm', 'cache', 'add', spec, '--prefer-online'],
                                 phase=f'native archive for {spec}', archive=archive)
                # Frozen exact latest: the release cannot change while readiness or installation retries.
                # Keep script output off the npm logger's stream so it cannot
                # splice a fragment onto a lifecycle record.
                wrapper = package + '@' + version
                self.command(['npm', 'install', '-g', '--include=optional', '--prefer-offline',
                              '--foreground-scripts=false', '--loglevel=info', wrapper],
                             install_specs, phase='global installation', merged=True, wrapper=wrapper)
                break
            except PublicationPending as failure:
                if attempt == self.args.attempts or time.monotonic() + self.args.interval >= self.deadline:
                    if self._journaled:
                        # The last attempt's evidence is on disk and every earlier
                        # attempt printed its own stream; the terminal summary still
                        # carries the tail and the retention path, so the reader of
                        # an exhausted budget sees the same evidence shape as any
                        # other failed install (issue #249).
                        self._print_journal_tail(merged=True)
                        note = f'; partial output retained at {journal_path(package)}'
                    else:
                        note = ''
                    raise ValueError(f'publication retry budget exhausted for {package}@{version} after {attempt} attempts{note}') from failure
                print(f'native release pending ({failure}); retry {attempt + 1}/{self.args.attempts} '
                      f'in {self.args.interval:g}s; keeping {package}@{version}', file=sys.stderr, flush=True)
                time.sleep(self.args.interval)
        root = self.command(['npm', 'root', '-g'], phase='global root lookup')
        installed = json.loads((Path(root) / package / 'package.json').read_text(encoding='utf-8'))
        if not isinstance(installed, dict) or installed.get('version') != version:
            raise ValueError(f'installed wrapper version differs from selected latest {package}@{version}')
        executable = 'opencode' if package == '@opencode/cli' else 'codex'
        print(self.command([executable, '--version'], phase='runtime version'), flush=True)
        print(f'installed {package}@{version} for linux-{arch}', flush=True)


def positive_float(value):
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError('must be finite and positive')
    return parsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', choices=('@opencode/cli', '@openai/codex'))
    parser.add_argument('arch', choices=('amd64', 'arm64'))
    parser.add_argument('--timeout', type=positive_float, default=600, help='total seconds, including npm commands (default: 600)')
    parser.add_argument('--interval', type=float, default=20, help='seconds between readiness attempts (default: 20)')
    parser.add_argument('--attempts', type=int, default=30, help='maximum native readiness attempts (default: 30)')
    args = parser.parse_args()
    if not math.isfinite(args.interval) or args.interval < 0 or args.attempts < 1:
        parser.error('interval must be finite and nonnegative; attempts must be positive')
    try:
        Installer(args).install()
    except (ValueError, OSError, UnicodeError) as failure:
        print(f'ERROR: {failure}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
