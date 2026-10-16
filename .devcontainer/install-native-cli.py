#!/usr/bin/env python3
"""Install one latest wrapper after its matching Linux native release is published."""
import argparse
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import time


class PublicationPending(Exception):
    """Only a known native dependency's missing registry version is retryable."""


class Installer:
    def __init__(self, args):
        self.args = args
        self.deadline = time.monotonic() + args.timeout

    def command(self, command, publication=False):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError('publication retry budget exhausted (elapsed time)')
        try:
            result = subprocess.run(command, capture_output=True, encoding='utf-8', timeout=min(120, remaining), check=False)
        except subprocess.TimeoutExpired as failure:
            # Preserve the first attempt's diagnostics even when the process hangs.
            for output in (failure.stdout, failure.stderr):
                if output:
                    print(output.decode('utf-8', errors='replace') if isinstance(output, bytes) else output, file=sys.stderr)
            raise ValueError('CLI installation command timed out within publication retry budget') from failure
        if result.returncode:
            print(result.stdout, end='', file=sys.stderr)
            print(result.stderr, end='', file=sys.stderr)
            # Never retry authentication, permissions, malformed metadata or wrapper lookup.
            codes = set(re.findall(r'npm (?:ERR!|error) code ([A-Z0-9_]+)', result.stderr))
            # A sentence-ending period is punctuation; version suffixes remain part of the token.
            tokens = {token.removesuffix('.') for token in re.findall(
                r'(?<![A-Za-z0-9_@/.+-])(@[a-z0-9._-]+/[a-z0-9._-]+@[0-9A-Za-z.+_-]+)(?![A-Za-z0-9_@/.+-])', result.stderr)}
            missing = publication is True or (publication and any(spec in tokens for spec in publication))
            if missing and codes and codes <= {'ETARGET', 'E404'}:
                raise PublicationPending(command[2] if publication is True else 'matching native dependency during install')
            raise ValueError(f'CLI installation command failed (exit {result.returncode}): {command[0]} {command[1]}')
        return result.stdout.strip()

    def metadata(self, spec, publication=False):
        return json.loads(self.command(['npm', 'view', spec, '--json', '--prefer-online'], publication))

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
                output = self.command(['npm', 'install', '-g', '--include=optional', '--prefer-online', package + '@' + version], install_specs)
                if output:
                    print(output)
                break
            except PublicationPending as failure:
                if attempt == self.args.attempts or time.monotonic() + self.args.interval >= self.deadline:
                    raise ValueError(f'publication retry budget exhausted for {package}@{version} after {attempt} attempts') from failure
                print(f'native release pending ({failure}); retry {attempt + 1}/{self.args.attempts} '
                      f'in {self.args.interval:g}s; keeping {package}@{version}', file=sys.stderr, flush=True)
                time.sleep(self.args.interval)
        root = self.command(['npm', 'root', '-g'])
        installed = json.loads((Path(root) / package / 'package.json').read_text(encoding='utf-8'))
        if not isinstance(installed, dict) or installed.get('version') != version:
            raise ValueError(f'installed wrapper version differs from selected latest {package}@{version}')
        executable = 'opencode' if package == '@opencode/cli' else 'codex'
        print(self.command([executable, '--version']), flush=True)
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
