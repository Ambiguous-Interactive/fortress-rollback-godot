#!/usr/bin/env python3
"""Install one latest wrapper after its matching Linux release is published."""
import argparse
import codecs
import json
import math
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import tempfile
import time


class PublicationPending(Exception):
    """Only a known native dependency's missing registry version is retryable."""


QUERY_CREDENTIALS = re.compile(r'(https?://[^\s?#]+)\?[^\s]*')

# One install's npm http log stays far below this; the cap bounds a pathological
# loop and each single line, so a stuck build cannot fill the disk with evidence.
JOURNAL_LIMIT_BYTES = 4 * 1024 * 1024
# A pathological stream without newlines still fills the line buffer; past this
# bound the partial line is flushed as complete evidence and counting resumes.
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
    return Path(tempfile.gettempdir()) / f'install-native-cli-{slug}.log'


def _open_journal(path):
    """Create or truncate the journal safely, or report why journaling is off.

    O_NOFOLLOW refuses a planted symlink, 0600 keeps other users out, and an
    unwritable or foreign-owned path must never turn the diagnostic feature
    into a new install failure, so the caller proceeds without a journal.
    """
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    except OSError as failure:
        return None, failure
    return os.fdopen(descriptor, 'wb'), None


def journal_tail(package):
    """The retained journal's redacted tail for a failure diagnostic (issue #249).

    The retention note alone names a path the failing CI context can never read
    again: a killed container or discarded Docker layer takes the file with it,
    which is exactly what the 2026-11-18 occurrence's job log shows. The tail
    therefore travels into the diagnostic stream itself. The read is bounded
    twice — only the file's last ``JOURNAL_TAIL_READ_BYTES`` are loaded, so a
    planted oversized file cannot exhaust memory, and the resulting lines are
    capped by the line and byte budgets — and every line is re-redacted so the
    diagnostic never depends on the writer. The first line of a truncated read
    is dropped as partial unless the read begins at the file's start.
    """
    path = journal_path(package)
    try:
        with path.open('rb') as source:
            start = source.seek(0, os.SEEK_END) - JOURNAL_TAIL_READ_BYTES
            partial = start > 0
            source.seek(max(0, start))
            data = source.read(JOURNAL_TAIL_READ_BYTES)
    except OSError:
        return []
    lines = data.decode('utf-8', errors='replace').splitlines()
    if partial and lines:
        # The cut can land inside a line; its consumed head is outside the read
        # and the remainder is not evidence on its own.
        lines = lines[1:]
    if not lines:
        return []
    tail = lines[-JOURNAL_TAIL_LINES:]
    if partial or len(lines) > JOURNAL_TAIL_LINES:
        tail.insert(0, f'...[journal head truncated; showing the last {len(tail)} lines]')
    kept = []
    remaining = JOURNAL_TAIL_BYTES
    for line in reversed(tail):
        # The budget bounds the diagnostic's UTF-8 output, so the count is
        # bytes, not characters: a multibyte line can exceed the budget while
        # its character count fits.
        budget = remaining - (len(line.encode('utf-8', errors='replace')) + 1)
        if budget < 0:
            break
        kept.append(line)
        remaining = budget
    if len(kept) < len(tail):
        kept.append(f'...[journal tail truncated at the {JOURNAL_TAIL_BYTES}-byte diagnostic budget]')
    return [redact_query_strings(line) for line in reversed(kept)]


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

    def _stream_with_journal(self, process, fileno, budget):
        """Collect the merged stream line by line into the fixed evidence journal.

        Each completed line is redacted and flushed as npm produces it, so an
        outer build deadline that kills this process mid-install still leaves
        the partial registry-versus-lifecycle evidence on disk (issue #249).
        Lines are buffered whole because the redaction regex needs the URL and
        its query in one piece; an incremental decoder keeps multi-byte
        sequences whole across read boundaries. Returns the collected text in
        npm's order.
        """
        path = journal_path(self.args.package)
        journal, failure = _open_journal(path)
        self._journaled = journal is not None
        if journal is None:
            # The diagnostic must never break the install it observes.
            print(f'install evidence journal disabled ({failure}); continuing without it',
                  file=sys.stderr, flush=True)
        else:
            print(f'install phase evidence journal: {path}', file=sys.stderr, flush=True)
        decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        collected = []
        pending = ''
        written = 0

        def record(line):
            """Redact one complete line into the journal within the byte budget."""
            nonlocal written
            if journal is None or written < 0:
                return
            data = redact_query_strings(line).encode('utf-8', errors='replace')
            try:
                if written + len(data) > JOURNAL_LIMIT_BYTES:
                    take = max(0, JOURNAL_LIMIT_BYTES - written)
                    # Decode the clamped head before writing, so the cut lands on
                    # a character boundary and the file stays valid UTF-8.
                    journal.write(data[:take].decode('utf-8', errors='replace').encode('utf-8'))
                    journal.write(b'\n...[journal truncated at the byte budget]\n')
                    journal.flush()
                    written = -1
                    return
                journal.write(data)
                # The flush is the point: a hard outer kill keeps only what
                # already reached the disk.
                journal.flush()
                written += len(data)
            except OSError as breakdown:
                # A journal that breaks mid-stream must not corrupt the collection.
                print(f'install evidence journal write failed ({breakdown}); continuing without it',
                      file=sys.stderr, flush=True)
                written = -1

        deadline = time.monotonic() + budget
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    if pending:
                        # The consumed bytes of an unterminated line are still evidence:
                        # journal them and keep them in the timeout diagnostic.
                        collected.append(pending)
                        record(pending)
                        pending = ''
                    raise subprocess.TimeoutExpired(process.args, budget, output=''.join(collected))
                ready, _, _ = select.select([fileno], [], [], min(left, 0.5))
                if not ready:
                    continue
                chunk = os.read(fileno, 65536)
                if not chunk:
                    pending += decoder.decode(b'', final=True)
                    break
                pending += decoder.decode(chunk, final=False)
                while True:
                    newline = pending.find('\n')
                    if newline < 0:
                        break
                    line = pending[:newline + 1]
                    pending = pending[newline + 1:]
                    collected.append(line)
                    record(line)
                if len(pending) > PENDING_LIMIT_BYTES:
                    # A pathological stream without newlines cannot buffer forever:
                    # flush the partial line as complete evidence and keep going.
                    collected.append(pending + '\n')
                    record(pending + '\n')
                    pending = ''
            if pending:
                # An incomplete final line is still evidence; keep its redaction safe
                # because the missing newline cannot split a URL mid-query.
                collected.append(pending)
                record(pending)
        finally:
            if journal is not None:
                try:
                    journal.close()
                except OSError as breakdown:
                    # A close-time flush failure must not bypass the caller's timeout
                    # handler, which owns the process-group cleanup.
                    print(f'install evidence journal close failed ({breakdown}); continuing without it',
                          file=sys.stderr, flush=True)
        # EOF means every writer closed the pipe; the direct child is exiting, so
        # this wait is bounded by its own teardown, not by a surviving descendant
        # (one would still hold the pipe open and prevent the EOF). The floor keeps
        # the bound positive when EOF lands exactly at the budget; its own expiry
        # raises into the caller's process-group cleanup.
        try:
            process.wait(timeout=max(0.1, min(10, deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            raise subprocess.TimeoutExpired(process.args, budget, output=''.join(collected)) from None
        return ''.join(collected)

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

    def command(self, command, publication=False, *, phase, merged=False):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError(f'publication retry budget exhausted before {phase} (elapsed time)')
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
        try:
            fileno = self._stream_fileno(process) if merged else None
            if fileno is not None:
                stdout = self._stream_with_journal(process, fileno, min(120, remaining))
                stderr = ''
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
            try:
                stdout, stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                # A descendant that escaped the group (setsid) can still hold the
                # pipes open; this build is failing anyway, so end the wait and
                # report the phase with whatever was collected.
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
            text = early + (stdout or '') + (stderr or '')
            if text:
                print(redact_query_strings(text), end='', file=sys.stderr)
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
            combined = redact_query_strings((result.stdout or '') + (result.stderr or ''))
            print(combined, end='', file=sys.stderr)
            # Never retry authentication, permissions, malformed metadata or wrapper lookup.
            codes = set(re.findall(r'npm (?:ERR!|error) code ([A-Z0-9_]+)', combined))
            # A sentence-ending period is punctuation; version suffixes remain part of the token.
            tokens = {token.removesuffix('.') for token in re.findall(
                r'(?<![A-Za-z0-9_@/.+-])(@[a-z0-9._-]+/[a-z0-9._-]+@[0-9A-Za-z.+_-]+)(?![A-Za-z0-9_@/.+-])', combined)}
            missing = publication is True or (publication and any(spec in tokens for spec in publication))
            if missing and codes and codes <= {'ETARGET', 'E404'}:
                raise PublicationPending(command[2] if publication is True else 'matching native dependency during install')
            if merged and self._journaled:
                self._print_journal_tail(merged)
                note = f'; partial output retained at {journal_path(self.args.package)}'
            else:
                note = ''
            raise ValueError(f'CLI installation command failed during {phase} (exit {result.returncode}){note}')
        if self._journaled:
            # A healthy install removes the evidence journal it created.
            journal_path(self.args.package).unlink(missing_ok=True)
        return result.stdout.strip()

    def metadata(self, spec, publication=False):
        phase = 'native metadata' if publication else 'wrapper metadata'
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
                # Frozen exact latest: the release cannot change while readiness or installation retries.
                # Foreground scripts stream the wrapper's postinstall (native version probe plus
                # nested fallback npm) into the merged stream, and the http loglevel names each
                # registry request, so a hang localizes to lifecycle execution versus acquisition.
                # The merged stream is journaled to disk line by line as npm produces it, so an
                # outer build deadline that kills this process still leaves the partial evidence
                # redacted and on disk at a fixed, discoverable path (issue #249). npm never
                # prints authorization material at this level, and the merged stream is only
                # printed on failure or timeout, in its original order.
                self.command(['npm', 'install', '-g', '--include=optional', '--prefer-online',
                              '--foreground-scripts', '--loglevel=http', package + '@' + version],
                             install_specs, phase='global installation', merged=True)
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
