"""Value: protects=CLI health and MCP discovery; fails_when=broken commands pass;
why_new=version/key smoke checks miss failures; seam=production shell helpers.
"""

from pathlib import Path
import os
import json
import re
import subprocess
import sys
import tempfile
import unittest


HELPERS = Path(__file__).resolve().parents[2] / ".devcontainer/verify-tools.sh"
ROOT = HELPERS.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from git_test_environment import fixture_environment


class ToolProbeTests(unittest.TestCase):
    def test_hooks_paths_resolve_to_repository_hooks(self):
        # Value: protects=equivalent hook paths and missing hooks; fails_when=raw strings decide; why_new=no hook validation coverage; seam=actual wiring block.
        script = (ROOT / ".devcontainer/verify.sh").read_text(encoding="utf-8")
        wiring = script.split('section "Wiring"\n', 1)[1].split('\nfor cfg in ', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            env = fixture_environment()
            repository = Path(directory) / "repository with spaces"
            repository.mkdir()
            subprocess.run(["git", "init", "-q", str(repository)], check=True, env=env, timeout=30)
            hooks = repository / ".githooks"
            hooks.mkdir()
            (repository / "other-hooks").mkdir()
            (repository / "hooks-link").symlink_to(hooks, target_is_directory=True)
            external = Path(directory) / "external"
            (external / "nested").mkdir(parents=True)
            (external / ".githooks").mkdir()
            (repository / "external-link").symlink_to(external / "nested", target_is_directory=True)
            (repository / "other-hooks/nested").mkdir()
            (repository / "internal-link").symlink_to(repository / "other-hooks/nested", target_is_directory=True)
            cases = [
                (".githooks", True),
                (".githooks/", True),
                (str(hooks), True),
                ("./other-hooks/../.githooks", True),
                ("hooks-link", True),
                ("external-link/../.githooks", False),
                ("internal-link/../../.githooks", True),
                (None, False),
                ("", False),
                ("other-hooks", False),
                ("missing-hooks", False),
            ]
            for configured, valid in cases:
                with self.subTest(configured=configured):
                    subprocess.run(["git", "-C", str(repository), "config", "--local", "--unset-all", "core.hooksPath"], check=False, env=env, timeout=30)
                    if configured is not None:
                        subprocess.run(["git", "-C", str(repository), "config", "--local", "core.hooksPath", configured], check=True, env=env, timeout=30)
                    result = subprocess.run(
                        ["bash", "-c", 'set -euo pipefail; ROOT="$1"; source "$2"; '
                         'ok() { echo PASS; }; bad() { echo FAIL; }; ' + wiring,
                         "probe", str(repository), str(HELPERS)],
                        cwd=directory, env=env, capture_output=True, text=True, check=True,
                        timeout=30,
                    )
                    self.assertEqual(result.stdout.strip(), "PASS" if valid else "FAIL")

    def probe(self, body, call):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "probe-tool"
            executable.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
            executable.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"])
            result = subprocess.run(
                ["bash", "-c", '''
set -euo pipefail
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; }
source "$1"
eval "$2"
''', "probe", str(HELPERS), call],
                env=env, capture_output=True, text=True, check=True,
                timeout=30,
            )
            return result.stdout

    def test_command_probe_checks_exit_status(self):
        cases = [
            ("echo 2.0.26", "PASS"),
            ("exit 42", "FAIL"),
            ("echo 2.0.26; exit 42", "FAIL"),
        ]
        for body, expected in cases:
            with self.subTest(body=body):
                self.assertIn(expected + ":", self.probe(body, "check_cmd probe-tool --version"))

    def test_major_probe_checks_exit_status_and_version(self):
        cases = [
            ("echo 'opencode v2.0.26'", "PASS"),
            ("echo 3.0.0", "PASS"),
            ("echo 1.99.0", "FAIL"),
            ("echo 'build 2000 unknown'", "FAIL"),
            ("exit 42", "FAIL"),
            ("echo 2.0.26; exit 42", "FAIL"),
        ]
        for body, expected in cases:
            with self.subTest(body=body):
                self.assertIn(expected + ":", self.probe(body, "check_major probe-tool 2"))

    def test_missing_command_fails(self):
        for call in ("check_cmd missing-fortress-tool --version", "check_major missing-fortress-tool 2"):
            with self.subTest(call=call):
                self.assertIn("FAIL:", self.probe("exit 0", call))

    def test_codex_requires_the_launched_executable_to_be_packaged(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            package = base / "packages/@openai/codex"
            (package / "bin").mkdir(parents=True)
            (package / "package.json").write_text("{}\n")
            launcher = package / "bin/codex.js"
            launcher.write_text("#!/bin/sh\nexit 0\n")
            launcher.chmod(0o755)
            bin_dir = base / "bin"
            bin_dir.mkdir()
            npm = bin_dir / "npm"
            npm.write_text(f"#!/bin/sh\nprintf '%s\\n' '{base / 'packages'}'\n")
            npm.chmod(0o755)
            codex = bin_dir / "codex"
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
            for packaged in (True, False):
                with self.subTest(packaged=packaged):
                    if packaged:
                        codex.symlink_to(launcher)
                    else:
                        codex.unlink()
                        codex.write_text("#!/bin/sh\nexit 0\n")
                        codex.chmod(0o755)
                    result = subprocess.run(
                        ["bash", "-c", 'ok() { echo PASS; }; bad() { echo FAIL; }; source "$1"; check_codex_package',
                         "probe", str(HELPERS)], env=env, capture_output=True, text=True, check=True,
                        timeout=30,
                    )
                    self.assertEqual(result.stdout.strip(), "PASS" if packaged else "FAIL")

    def test_runtime_discovery_initializes_and_checks_all_names_without_logging_secrets(self):
        def catalog(entries):
            return json.dumps({"data": [
                {"name": name, "status": {"status": status}}
                for name, status in entries
            ]})

        all_names = [("godot", "connected"), ("context7", "failed"), ("github", "pending")]
        cases = [
            (catalog(all_names), "PASS", 0, 0),
            (catalog([]), "FAIL", 0, 0),
            (catalog(all_names[:2]), "FAIL", 0, 0),
            (catalog(all_names), "FAIL", 42, 0),
            (catalog(all_names), "FAIL", 0, 42),
            ('{"error":"godot context7 github PRIVATE-SECRET"}', "FAIL", 0, 0),
            ('{"data":[{"name":null}]}', "FAIL", 0, 0),
        ]
        for status in ("needs_auth", "expired", "disabled", "future_status"):
            cases.append((catalog([(name, status) for name, _ in all_names]), "PASS", 0, 0))
        for output, expected, exit_code, init_exit in cases:
            with self.subTest(output=output, exit_code=exit_code, init_exit=init_exit), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                executable = base / "opencode"
                executable.write_text(
                    '#!/bin/sh\n'
                    'if [ "$1 $2" = "debug config" ]; then\n'
                    f'  touch initialized; echo PRIVATE-SECRET; exit {init_exit}\n'
                    'fi\n'
                    '[ -f initialized ] || exit 43\n'
                    '[ \"$1 $2 $3\" = \"api mcp.list --param\" ] || exit 44\n'
                    '[ \"$4\" = \"location[directory]=$PWD\" ] || exit 45\n'
                    f"cat <<'OUTPUT'\n{output}\nOUTPUT\nexit {exit_code}\n"
                )
                executable.chmod(0o755)
                env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"])
                result = subprocess.run(
                    ["bash", "-c", 'ok() { echo "PASS: $*"; }; bad() { echo "FAIL: $*"; }; source "$1"; check_opencode_runtime "$2" 1',
                     "probe", str(HELPERS), directory],
                    env=env, capture_output=True, text=True, check=True,
                    timeout=30,
                )
                self.assertIn(expected + ":", result.stdout)
                if expected == "PASS":
                    self.assertNotIn("FAIL:", result.stdout)
                self.assertNotIn("PRIVATE-SECRET", result.stdout + result.stderr)

    def test_runtime_discovery_waits_for_asynchronous_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            executable = base / "opencode"
            catalog = json.dumps({"data": [
                {"name": "godot", "status": {"status": "pending"}},
                {"name": "context7", "status": {"status": "needs_auth"}},
                {"name": "github", "status": {"status": "failed", "error": "PRIVATE-SECRET"}},
            ]})
            executable.write_text(
                '#!/bin/sh\n'
                'if [ "$1 $2" = "debug config" ]; then\n'
                '  touch initialized; echo PRIVATE-SECRET; exit 0\n'
                'fi\n'
                '[ -f initialized ] || exit 43\n'
                '[ "$1 $2 $3" = "api mcp.list --param" ] || exit 44\n'
                '[ "$4" = "location[directory]=$PWD" ] || exit 45\n'
                'if [ ! -f listed ]; then\n'
                "  touch listed; echo '{\"data\":[]}'; exit 0\n"
                'fi\n'
                f"cat <<'OUTPUT'\n{catalog}\nOUTPUT\n"
            )
            executable.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"])
            result = subprocess.run(
                ["bash", "-c", 'ok() { echo "PASS: $*"; }; bad() { echo "FAIL: $*"; }; source "$1"; check_opencode_runtime "$2" 5',
                 "probe", str(HELPERS), directory],
                env=env, capture_output=True, text=True, check=True, timeout=10,
            )
            self.assertEqual(result.stdout.count("PASS:"), 3)
            self.assertNotIn("FAIL:", result.stdout)
            self.assertNotIn("PRIVATE-SECRET", result.stdout + result.stderr)

    def test_real_mcp_predicates_reject_bad_commands_and_disabled_servers(self):
        config = json.loads((ROOT / "opencode.json").read_text())
        variants = [(config, True)]
        for command in (["does-not-exist", "godot-mcp"], "godot-mcp", []):
            variant = json.loads(json.dumps(config))
            variant["mcp"]["servers"]["godot"]["command"] = command
            variants.append((variant, False))
        for disabled in (True, None, "false"):
            variant = json.loads(json.dumps(config))
            variant["mcp"]["servers"]["godot"]["disabled"] = disabled
            variants.append((variant, False))
        for path in (ROOT / ".devcontainer/verify.sh", ROOT / ".github/workflows/devcontainer.yml"):
            # Exercise the actual production predicates; do not duplicate jq logic.
            predicates = re.findall(r"jq -e '\n(.*?)\n\s*'", path.read_text(), re.S)
            predicate = next(item for item in predicates if ".mcp.servers" in item)
            for variant, valid in variants:
                with self.subTest(path=path, valid=valid, godot=variant["mcp"]["servers"]["godot"]):
                    result = subprocess.run(
                        ["jq", "-e", predicate], input=json.dumps(variant), capture_output=True, text=True,
                        timeout=30,
                    )
                    self.assertEqual(result.returncode == 0, valid)


if __name__ == "__main__":
    unittest.main()
