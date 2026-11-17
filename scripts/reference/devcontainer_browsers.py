"""Acquire the pinned browser witnessing capability for the devcontainer.

Downloads (digest-bound to docs/reference/pins.json) and unpacks the pinned
Chromium and Firefox builds into the cache layouts the reference harness
already reads, and records `.cache/reference/browser-env.sh` with the
environment variables the skip-gated browser suites consume. npm installs the
pinned Playwright package; this module owns the digest verification, the
unpacking and the environment fragment. Verification of the settled state and
the real launch witnesses live in `.devcontainer/verify.sh`; acquisition never
weakens a pin and every mismatch fails closed with a named error.
"""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

from fetch import CACHE, digest, load_manifest, fetch, prepare_zip

PACKAGE_RELATIVES = ('@playwright/test', 'playwright', 'playwright-core')

UNSUPPORTED_ARCH = 'pinned browsers are unavailable for this architecture'
MISSING_EXECUTABLE = 'acquired browser executable is missing or not executable'
REGISTRY_MISMATCH = 'Playwright browser registry differs from the pin'

BASHRC_MARKER = '# fortress devcontainer browser capability'


def arch_from_uname(machine):
    """Map the container architecture onto the pin artifact suffixes."""
    mapping = {'x86_64': 'x86_64', 'aarch64': 'arm64', 'arm64': 'arm64'}
    if machine not in mapping:
        raise ValueError(f'{UNSUPPORTED_ARCH}: {machine} (expected x86_64 or aarch64/arm64)')
    return mapping[machine]


def chromium_zip_name(data, arch):
    return f"chromium-{data['browser']['chromium_revision']}-{arch}.zip"


def firefox_zip_name(data, arch):
    return f"firefox-{data['browser']['firefox_revision']}-ubuntu24.04-{arch}.zip"


def acquire_chromium(data, arch, offline=False, cache=CACHE):
    """Fetch and publish the pinned Chromium build; return its executable."""
    name = chromium_zip_name(data, arch)
    archive = fetch(data['artifacts'][name], name, offline, cache=cache)
    installation = cache / 'verified-browser' / arch
    member = data['browser']['chromium_executables'][arch]
    executable = installation / member
    prepare_zip(archive, installation, executable_members=(member,))
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f'{MISSING_EXECUTABLE}: {executable}')
    return executable


def acquire_firefox(data, arch, offline=False, cache=CACHE):
    """Fetch and publish the pinned Firefox build; return its executable."""
    name = firefox_zip_name(data, arch)
    archive = fetch(data['artifacts'][name], name, offline, cache=cache)
    installation = cache / 'webrtc-firefox' / arch
    executable = installation / 'firefox/firefox'
    prepare_zip(archive, installation, executable_members=('firefox/firefox',))
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f'{MISSING_EXECUTABLE}: {executable}')
    return executable


def verify_playwright_package(data, node_modules):
    """Require the npm-installed package closure and the pinned registry."""
    node_modules = Path(node_modules)
    for relative in PACKAGE_RELATIVES:
        if not (node_modules / relative).is_dir():
            raise ValueError(f'Playwright package closure incomplete: node_modules/{relative} is missing')
    registry = node_modules / 'playwright-core/browsers.json'
    if digest(registry) != data['browser']['browser_registry_sha256']:
        raise ValueError(REGISTRY_MISMATCH)
    return registry


def environment_fragment(chromium, firefox, package):
    """Environment fragment consumed by verify.sh and the skip-gated suites.

    Every value is quoted shell-safely: the checkout path is user-controlled
    and may contain spaces or shell metacharacters.
    """
    lines = [
        '# Written by scripts/reference/devcontainer_browsers.py (post-create).',
        '# Sourced by .devcontainer/verify.sh and interactive shells; do not edit by hand.',
        f'export FORTRESS_CHROMIUM_EXECUTABLE={shlex.quote(str(chromium))}',
        f'export FORTRESS_FIREFOX_EXECUTABLE={shlex.quote(str(firefox))}',
        f'export FORTRESS_PLAYWRIGHT_PACKAGE={shlex.quote(str(package))}',
    ]
    return '\n'.join(lines) + '\n'


def write_environment_fragment(chromium, firefox, package, target):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + '.temporary')
    temporary.write_text(environment_fragment(chromium, firefox, package))
    temporary.replace(target)
    return target


def ensure_bashrc_source(fragment, bashrc, marker=BASHRC_MARKER):
    """Point interactive shells at the fragment exactly once (idempotent)."""
    bashrc = Path(bashrc)
    source_line = f'. "{fragment}"'
    existing = bashrc.read_text() if bashrc.exists() else ''
    if marker in existing and source_line in existing:
        return False
    with bashrc.open('a') as output:
        if existing and not existing.endswith('\n'):
            output.write('\n')
        output.write(f'\n{marker}\n{source_line}\n')
    return True


def npm_install_package(root, package_cache, npm='npm', offline=False):
    """Install the pinned Playwright npm package exactly as CI does.

    `offline` forbids network use entirely (npm's own offline mode), so an
    offline acquisition cannot silently fetch packages over the network; the
    post-create path stays online and keeps the CI-identical invocation.
    """
    sources = Path(root) / 'scripts/reference/browser'
    package_cache = Path(package_cache)
    package_cache.mkdir(parents=True, exist_ok=True)
    for name in ('package.json', 'package-lock.json'):
        shutil.copyfile(sources / name, package_cache / name)
    arguments = [npm, 'ci', '--ignore-scripts', '--prefix', str(package_cache)]
    if offline:
        arguments.append('--offline')
    result = subprocess.run(
        arguments, cwd=str(package_cache), capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        raise ValueError('npm ci failed for the pinned Playwright package: '
                         + (detail[-1] if detail else f'exit {result.returncode}'))
    return package_cache / 'node_modules'


def acquire(root, arch, offline=False, bashrc=None, cache=CACHE, npm='npm'):
    """Acquire every pinned piece and record the environment fragment."""
    data = load_manifest()
    chromium = acquire_chromium(data, arch, offline, cache=cache)
    firefox = acquire_firefox(data, arch, offline, cache=cache)
    node_modules = npm_install_package(root, cache / 'browser', npm, offline=offline)
    verify_playwright_package(data, node_modules)
    package = node_modules / '@playwright/test'
    fragment = write_environment_fragment(chromium, firefox, package, cache / 'browser-env.sh')
    changed = ensure_bashrc_source(fragment, bashrc if bashrc is not None else Path.home() / '.bashrc')
    return {'chromium': chromium, 'firefox': firefox, 'package': package,
            'fragment': fragment, 'bashrc_updated': changed}


def main_with_args(argv, out=sys.stdout):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--arch', default=arch_from_uname(os.uname().machine),
                        help='pin artifact suffix (x86_64 or arm64); defaults to this machine')
    parser.add_argument('--offline', action='store_true', help='refuse network downloads; cache hits only')
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[2]
    acquired = acquire(root, args.arch, args.offline)
    for name in ('chromium', 'firefox', 'package', 'fragment'):
        out.write(f'{name}: {acquired[name]}\n')
    out.write(f'bashrc_updated: {acquired["bashrc_updated"]}\n')
    return acquired


if __name__ == '__main__':
    main_with_args(sys.argv[1:])
