"""Exercise the actual CI mirror preparation command on owned APT fixtures."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMMAND = ROOT / 'scripts/reference/prepare_ubuntu_apt.sh'
ARCHIVE = 'https://archive.ubuntu.com/ubuntu/\tpriority:2\n'
SECURITY = 'https://security.ubuntu.com/ubuntu/\tpriority:3\n'
AZURE = 'http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n'


def source_text(fields):
    return '\n\n'.join('Types: deb\n' + stanza + '\nSuites: noble\nComponents: main\n'
                       'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n'
                       for stanza in fields.split('\n\n'))


# Value: protects=CI removes slow Azure preference without altering trusted alternatives or source signatures;
# fails_when=preparation corrupts fallback/configuration or accepts an unused mirror; why_new=real OS setup stalled; seam=owned CLI file inputs
class UbuntuMirrorTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / '.cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        owned = tempfile.TemporaryDirectory(prefix='apt-fixture-', dir=scratch)
        self.addCleanup(owned.cleanup)
        self.directory = Path(owned.name)
        self.mirrors = self.directory / 'mirrors.txt'
        self.sources = self.directory / 'ubuntu.sources'
        self.source_bytes = source_text(f'URIs: mirror+file:{self.mirrors}').encode()
        self.sources.write_bytes(self.source_bytes)

    def run_command(self, environment=None):
        return subprocess.run(['bash', str(COMMAND), str(self.sources), str(self.mirrors)],
                              capture_output=True, text=True, encoding='utf-8', timeout=10, env=environment)

    def test_selects_existing_https_alternatives(self):
        for azure in (AZURE, AZURE.replace('http:', 'https:'), AZURE.replace('.com/', '.com:80/')):
            with self.subTest(azure=azure):
                self.mirrors.write_text('# retain this comment\n' + azure + ARCHIVE + SECURITY)
                os.chmod(self.mirrors, 0o644)
                result = self.run_command()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.mirrors.read_text(), '# retain this comment\n' + ARCHIVE + SECURITY)
                self.assertEqual(self.sources.read_bytes(), self.source_bytes)
                self.assertEqual(self.mirrors.stat().st_mode & 0o777, 0o644)
                self.assertEqual(sorted(p.name for p in self.directory.iterdir()), ['mirrors.txt', 'ubuntu.sources'])

    def test_repeated_preparation_does_not_rewrite_healthy_file(self):
        self.mirrors.write_text(ARCHIVE + SECURITY)
        before = self.mirrors.stat()
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        after = self.mirrors.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        self.assertEqual(self.mirrors.read_text(), ARCHIVE + SECURITY)

    def test_missing_fallback_or_reference_leaves_files_unchanged(self):
        for content, reference in ((AZURE + ARCHIVE, True), (AZURE + SECURITY, True),
                                   (AZURE, True), ('', True), (AZURE + ARCHIVE + SECURITY, False)):
            with self.subTest(content=content, reference=reference):
                self.mirrors.write_text(content)
                source = self.source_bytes if reference else source_text('URIs: https://archive.ubuntu.com/ubuntu/').encode()
                self.sources.write_bytes(source)
                result = self.run_command()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.mirrors.read_text(), content)
                self.assertEqual(self.sources.read_bytes(), source)
                self.assertEqual(sorted(p.name for p in self.directory.iterdir()), ['mirrors.txt', 'ubuntu.sources'])

    def test_comments_and_other_hosts_are_preserved(self):
        extra = '# http://azure.archive.ubuntu.com/ubuntu/\nhttps://azure.archive.ubuntu.com.example/ubuntu/\n'
        self.mirrors.write_text(AZURE + ARCHIVE + SECURITY + extra)
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mirrors.read_text(), ARCHIVE + SECURITY + extra)

    def test_inactive_and_lookalike_references_are_rejected_without_mutation(self):
        target = f'mirror+file:{self.mirrors}'
        for fields in (f'# URIs: {target}\nURIs: http://azure.archive.ubuntu.com/ubuntu/',
                       f'URIs: {target}.other', f'URIs: {target}/dists/other',
                       f'URIs: {target}\nEnabled: no', f'URIs: {target}\nEnabled : no',
                       f'URIs: {target}\nEnabled: false', f'URIs: {target}\nEnabled: 0',
                       f'URIs: {target}\nURIs: https://example.invalid/ubuntu/',
                       f'URIs: {target}\nURIs : https://example.invalid/ubuntu/',
                       f'URIs: {target}\nEnabled: yes\nEnabled: no'):
            with self.subTest(fields=fields):
                content = AZURE + ARCHIVE + SECURITY
                source = source_text(fields)
                self.mirrors.write_text(content)
                self.sources.write_text(source)
                result = self.run_command()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.mirrors.read_text(), content)
                self.assertEqual(self.sources.read_text(), source)

    def test_effective_apt_uri_fields_and_continuations_are_accepted(self):
        target = f'mirror+file:{self.mirrors}'
        for fields in (f'URIs: {target}', f'URIs:{target}', f'URIs : {target}',
                       f'URIs: https://example.invalid/ubuntu/ {target}',
                       f'URIs:\n {target}', f'URIs: https://example.invalid/ubuntu/\n# comment\n\t{target}',
                       f'URIs: https://example.invalid/ubuntu/\n\nURIs: {target}',
                       f'URIs: {target}\nEnabled: yes', f'URIs: {target}\nEnabled:\n yes',
                       f'URIs: {target}\nEnabled: unknown',
                       f'URIs: https://example.invalid/ubuntu/\nURIs: {target}',
                       f'URIs: {target}\nEnabled: no\nEnabled: yes'):
            with self.subTest(fields=fields):
                source = source_text(fields)
                self.mirrors.write_text(AZURE + ARCHIVE + SECURITY)
                self.sources.write_text(source)
                result = self.run_command()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.mirrors.read_text(), ARCHIVE + SECURITY)
                self.assertEqual(self.sources.read_text(), source)

    def test_planning_does_not_fetch_or_use_callers_apt_hooks(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            listener.setblocking(False)
            target = f'mirror+file:{self.mirrors}'
            self.sources.write_text(source_text(f'URIs: {target} http://127.0.0.1:{listener.getsockname()[1]}/ubuntu/'))
            self.mirrors.write_text(AZURE + ARCHIVE + SECURITY)
            marker = self.directory / 'hook-executed'
            configuration = self.directory / 'caller-apt.conf'
            configuration.write_text(f'APT::Update::Pre-Invoke {{ "touch {marker}"; }};\n')
            environment = os.environ.copy()
            environment['APT_CONFIG'] = str(configuration)
            result = self.run_command(environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())
            with self.assertRaises(BlockingIOError):
                listener.accept()


if __name__ == '__main__':
    unittest.main()
