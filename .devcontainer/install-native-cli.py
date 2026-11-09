#!/usr/bin/env python3
"""Install one latest wrapper after its matching Linux release is published."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


class PublicationPending(Exception):
    """Only a known native dependency's missing registry version is retryable."""


QUERY_CREDENTIALS = re.compile(r'(https?://[^\s?#]+)\?[^\s]*')


def redact_query_strings(text):
    """Strip query strings from diagnostic URLs, keeping host and path.

    A configured registry can hand out signed download redirects, and the http
    loglevel prints those URLs. The credentials live in the query, so failure
    and timeout diagnostics never print one.
    """
    return QUERY_CREDENTIALS.sub(r'\1?<redacted>', text)


class Installer:
    def __init__(self, args):
        self.args = args
        self.deadline = time.monotonic() + args.timeout

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
            stdout, stderr = process.communicate(timeout=min(120, remaining))
        except subprocess.TimeoutExpired as failure:
            # Preserve the first attempt's diagnostics even when the process tree
            # hangs, in the order npm produced them, without registry credentials.
            os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            stdout, stderr = process.communicate()
            text = (stdout or '') + (stderr or '')
            if text:
                print(redact_query_strings(text), end='', file=sys.stderr)
            raise ValueError(f'CLI installation command timed out during {phase} within publication retry budget') from failure
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
            raise ValueError(f'CLI installation command failed during {phase} (exit {result.returncode})')
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
                # npm never prints authorization material at this level, and the merged stream is
                # only printed on failure or timeout, in its original order.
                self.command(['npm', 'install', '-g', '--include=optional', '--prefer-online',
                              '--foreground-scripts', '--loglevel=http', package + '@' + version],
                             install_specs, phase='global installation', merged=True)
                break
            except PublicationPending as failure:
                if attempt == self.args.attempts or time.monotonic() + self.args.interval >= self.deadline:
                    raise ValueError(f'publication retry budget exhausted for {package}@{version} after {attempt} attempts') from failure
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
