"""Value: protects=devcontainer browser acquisition; fails_when=digest drift or
partial installs pass; why_new=the browser capability (#385) must fail closed on
corrupt caches, missing executables, registry drift and npm failures;
seam=scripts/reference/devcontainer_browsers.py fixture cache.
"""
import hashlib
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import devcontainer_browsers as browsers
from fetch import digest, load_manifest


def executable_zip(files, executable_names=()):
    """One in-memory zip whose named members carry the executable attribute."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as package:
        for name, payload in files.items():
            info = zipfile.ZipInfo(name)
            mode = 0o755 if name in executable_names else 0o644
            info.external_attr = mode << 16
            package.writestr(info, payload)
    return buffer.getvalue()


# Distinct fixture revisions, so a fixture artifact can never collide with a
# real pinned artifact name from docs/reference/pins.json.
FIXTURE_CHROMIUM_MEMBER = 'chrome-linux64/chrome'


def fake_pins(registry_digest='f' * 64):
    browser = {'chromium_revision': '99', 'firefox_revision': '66',
               'browser_registry_sha256': registry_digest,
               'chromium_executables': {'x86_64': FIXTURE_CHROMIUM_MEMBER, 'arm64': FIXTURE_CHROMIUM_MEMBER}}
    chromium_files = {'chrome-linux64/chrome': 'chromium-bytes', 'chrome-linux64/resources.pak': 'pak'}
    firefox_files = {'firefox/firefox': 'firefox-bytes', 'firefox/omni.ja': 'omni'}
    data = {'browser': browser, 'artifacts': {}}
    payloads = {browsers.chromium_zip_name(data, 'x86_64'): executable_zip(chromium_files, (FIXTURE_CHROMIUM_MEMBER,)),
                browsers.chromium_zip_name(data, 'arm64'): executable_zip(chromium_files, (FIXTURE_CHROMIUM_MEMBER,)),
                browsers.firefox_zip_name(data, 'x86_64'): executable_zip(firefox_files, ('firefox/firefox',)),
                browsers.firefox_zip_name(data, 'arm64'): executable_zip(firefox_files, ('firefox/firefox',))}
    for name, payload in payloads.items():
        data['artifacts'][name] = {'algorithm': 'sha256',
                                   'digest': hashlib.sha256(payload).hexdigest(),
                                   'url': f'https://invalid.example/never-contacted/{name}'}
    return data


def make_package_sources(root):
    """The scripts/reference/browser sources npm_install_package copies from."""
    sources = Path(root) / 'scripts/reference/browser'
    sources.mkdir(parents=True, exist_ok=True)
    (sources / 'package.json').write_text('{"name":"fixture"}\n')
    (sources / 'package-lock.json').write_text('{"lock":true}\n')
    return sources


class AcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.cache = Path(self.directory.name) / 'cache'
        self.data = fake_pins()
        # Build payloads once per test so digests always agree with the pins.
        self.payloads = {}
        chromium_files = {'chrome-linux64/chrome': 'chromium-bytes', 'chrome-linux64/resources.pak': 'pak'}
        firefox_files = {'firefox/firefox': 'firefox-bytes', 'firefox/omni.ja': 'omni'}
        for name, pin in self.data['artifacts'].items():
            files, executables = ((chromium_files, (FIXTURE_CHROMIUM_MEMBER,)) if name.startswith('chromium-')
                                  else (firefox_files, ('firefox/firefox',)))
            payload = executable_zip(files, executables)
            self.payloads[name] = payload
            pin['digest'] = hashlib.sha256(payload).hexdigest()
            target = self.cache / 'downloads' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)

    def tearDown(self):
        self.directory.cleanup()

    def test_arch_mapping_and_named_refusal(self):
        self.assertEqual(browsers.arch_from_uname('x86_64'), 'x86_64')
        self.assertEqual(browsers.arch_from_uname('aarch64'), 'arm64')
        self.assertEqual(browsers.arch_from_uname('arm64'), 'arm64')
        with self.assertRaisesRegex(ValueError, browsers.UNSUPPORTED_ARCH):
            browsers.arch_from_uname('armv7l')

    def test_chromium_acquisition_publishes_executable_member(self):
        executable = browsers.acquire_chromium(self.data, 'arm64', offline=True, cache=self.cache)
        self.assertEqual(executable, self.cache / 'verified-browser/arm64/chrome-linux64/chrome')
        self.assertTrue(executable.is_file())
        pak = self.cache / 'verified-browser/arm64/chrome-linux64/resources.pak'
        self.assertEqual(pak.read_bytes(), b'pak')

    def test_firefox_acquisition_publishes_executable_member(self):
        executable = browsers.acquire_firefox(self.data, 'arm64', offline=True, cache=self.cache)
        self.assertEqual(executable, self.cache / 'webrtc-firefox/arm64/firefox/firefox')
        self.assertTrue(executable.is_file())

    def test_corrupt_cached_download_is_refused_with_the_pinned_digest(self):
        name = browsers.chromium_zip_name(self.data, 'arm64')
        target = self.cache / 'downloads' / name
        mutated = bytearray(target.read_bytes())
        mutated[100] ^= 0xFF
        target.write_bytes(bytes(mutated))
        with self.assertRaisesRegex(ValueError, 'digest mismatch'):
            browsers.acquire_chromium(self.data, 'arm64', offline=True, cache=self.cache)

    def test_missing_executable_member_is_a_named_failure(self):
        data = fake_pins()
        data['browser']['chromium_executables'] = {'x86_64': 'chrome-linux64/absent/chrome',
                                                   'arm64': 'chrome-linux64/absent/chrome'}
        payload = executable_zip({'chrome-linux64/other': 'bytes'})
        name = browsers.chromium_zip_name(data, 'arm64')
        pin = data['artifacts'][name]
        pin['digest'] = hashlib.sha256(payload).hexdigest()
        target = self.cache / 'downloads' / name
        target.write_bytes(payload)
        with self.assertRaisesRegex(ValueError, browsers.MISSING_EXECUTABLE):
            browsers.acquire_chromium(data, 'arm64', offline=True, cache=self.cache)

    def test_package_closure_and_registry_verification(self):
        node_modules = self.cache / 'browser/node_modules'
        for relative in browsers.PACKAGE_RELATIVES:
            (node_modules / relative).mkdir(parents=True, exist_ok=True)
        registry = node_modules / 'playwright-core/browsers.json'
        registry.write_text('{}')
        with self.assertRaisesRegex(ValueError, browsers.REGISTRY_MISMATCH):
            browsers.verify_playwright_package(self.data, node_modules)
        registry.write_text('[]')
        # Pin the registry digest to the real bytes and require the closure.
        self.data['browser']['browser_registry_sha256'] = digest(registry)
        self.assertEqual(browsers.verify_playwright_package(self.data, node_modules), registry)
        shutil.rmtree(node_modules / 'playwright')
        with self.assertRaisesRegex(ValueError, 'node_modules/playwright is missing'):
            browsers.verify_playwright_package(self.data, node_modules)

    def test_environment_fragment_records_the_three_exports(self):
        text = browsers.environment_fragment('/chromium/path', '/firefox/path', '/package/path')
        self.assertIn('export FORTRESS_CHROMIUM_EXECUTABLE=/chromium/path', text)
        self.assertIn('export FORTRESS_FIREFOX_EXECUTABLE=/firefox/path', text)
        self.assertIn('export FORTRESS_PLAYWRIGHT_PACKAGE=/package/path', text)
        self.assertTrue(text.endswith('\n'))

    def test_fragment_write_is_atomic_and_complete(self):
        target = self.cache / 'browser-env.sh'
        written = browsers.write_environment_fragment('/c', '/f', '/p', target)
        self.assertEqual(written, target)
        self.assertFalse(target.with_name(target.name + '.temporary').exists())
        self.assertEqual(target.read_text(), browsers.environment_fragment('/c', '/f', '/p'))

    def test_bashrc_source_is_idempotent_and_safe_for_untterminated_files(self):
        bashrc = self.cache / 'home-bashrc'
        bashrc.write_text('export PATH="/existing/bin:$PATH"')  # no trailing newline
        self.assertTrue(browsers.ensure_bashrc_source('/fragment.sh', bashrc))
        text = bashrc.read_text()
        self.assertIn('export PATH="/existing/bin:$PATH"\n', text)
        self.assertIn('. "/fragment.sh"', text)
        self.assertFalse(browsers.ensure_bashrc_source('/fragment.sh', bashrc))
        self.assertEqual(text.count('. "/fragment.sh"'), (bashrc.read_text()).count('. "/fragment.sh"'))

    def test_npm_failure_names_the_tool_error(self):
        fake = self.cache / 'fake-bin/npm'
        fake.parent.mkdir(parents=True, exist_ok=True)
        fake.write_text('#!/bin/sh\necho "npm error code EAI_AGAIN" >&2\nexit 1\n')
        fake.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'npm error code EAI_AGAIN'):
            browsers.npm_install_package(make_package_sources(self.cache).parents[2],
                                         self.cache / 'browser', npm=str(fake))

    def test_npm_failure_without_output_names_the_exit_code(self):
        fake = self.cache / 'fake-bin/npm'
        fake.parent.mkdir(parents=True, exist_ok=True)
        fake.write_text('#!/bin/sh\nexit 7\n')
        fake.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'exit 7'):
            browsers.npm_install_package(make_package_sources(self.cache).parents[2],
                                         self.cache / 'browser', npm=str(fake))

    def test_npm_success_invokes_ci_with_ignore_scripts_and_copies_the_lockfile(self):
        observed = {}
        fake = self.cache / 'fake-bin/npm'
        fake.parent.mkdir(parents=True, exist_ok=True)
        fake.write_text('#!/bin/sh\nexit 0\n')
        fake.chmod(0o755)
        root = make_package_sources(self.cache).parents[2]
        with patch.object(browsers.subprocess, 'run') as mocked:
            def record(arguments, **_):
                observed['arguments'] = arguments
                return type('Result', (), {'returncode': 0, 'stdout': '', 'stderr': ''})()
            mocked.side_effect = record
            browsers.npm_install_package(root, self.cache / 'browser', npm=str(fake))
        self.assertIn('--ignore-scripts', observed['arguments'])
        self.assertIn('--prefix', observed['arguments'])
        self.assertTrue((self.cache / 'browser/package-lock.json').is_file())


class EndToEndTests(unittest.TestCase):
    def test_acquire_records_fragment_and_bashrc_from_fixture_cache(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            cache = root / 'cache'
            data = fake_pins()
            chromium_files = {'chrome-linux64/chrome': 'chromium-bytes'}
            firefox_files = {'firefox/firefox': 'firefox-bytes'}
            for name, pin in data['artifacts'].items():
                files, executables = ((chromium_files, (FIXTURE_CHROMIUM_MEMBER,)) if name.startswith('chromium-')
                                      else (firefox_files, ('firefox/firefox',)))
                payload = executable_zip(files, executables)
                pin['digest'] = hashlib.sha256(payload).hexdigest()
                target = cache / 'downloads' / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(payload)
            node_modules = cache / 'browser/node_modules'
            for relative in browsers.PACKAGE_RELATIVES:
                (node_modules / relative).mkdir(parents=True, exist_ok=True)
            registry = node_modules / 'playwright-core/browsers.json'
            registry.write_text('{}')
            data['browser']['browser_registry_sha256'] = digest(registry)
            fake = root / 'fake-bin/npm'
            fake.parent.mkdir(parents=True, exist_ok=True)
            fake.write_text('#!/bin/sh\nexit 0\n')
            fake.chmod(0o755)
            make_package_sources(root)
            bashrc = root / 'bashrc'
            with patch.object(browsers, 'load_manifest', return_value=data):
                acquired = browsers.acquire(root, 'arm64', offline=True, bashrc=bashrc, cache=cache, npm=str(fake))
            fragment = acquired['fragment']
            self.assertEqual(fragment, cache / 'browser-env.sh')
            self.assertIn(f"export FORTRESS_CHROMIUM_EXECUTABLE={cache / 'verified-browser/arm64/chrome-linux64/chrome'}",
                          fragment.read_text())
            self.assertIn(f"export FORTRESS_FIREFOX_EXECUTABLE={cache / 'webrtc-firefox/arm64/firefox/firefox'}",
                          fragment.read_text())
            self.assertIn(f"export FORTRESS_PLAYWRIGHT_PACKAGE={node_modules / '@playwright/test'}",
                          fragment.read_text())
            self.assertIn(f'. "{fragment}"', bashrc.read_text())
            self.assertTrue(acquired['bashrc_updated'])


class ManifestConsistencyTests(unittest.TestCase):
    def test_real_pins_and_module_names_stay_in_sync(self):
        """The module's artifact names must resolve against the committed pins."""
        data = load_manifest()
        for arch in ('x86_64', 'arm64'):
            chromium = browsers.chromium_zip_name(data, arch)
            firefox = browsers.firefox_zip_name(data, arch)
            self.assertIn(chromium, data['artifacts'])
            self.assertIn(firefox, data['artifacts'])
        self.assertIn(data['browser']['chromium_executables']['arm64'],
                      ('chrome-linux-arm64/chrome', 'chrome-linux64/chrome'))


if __name__ == '__main__':
    unittest.main()
