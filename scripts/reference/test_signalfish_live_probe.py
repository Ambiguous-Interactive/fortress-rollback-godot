"""Value: live relay evidence rejects incomplete gameplay and unbound server build receipts."""
import copy
import json
import hashlib
import os
from pathlib import Path
import tempfile
import unittest

import signalfish_live_probe as probe


class LiveRelayEvidenceControls(unittest.TestCase):
    def test_all_relevant_sdk_failure_and_membership_events_have_controls(self):
        self.assertEqual(set(probe.LATE_ERRORS), {'protocol_error', 'server_error', 'room_join_failed', 'authentication_error', 'connection_failed',
                                                'reconnection_failed', 'disconnected', 'going_away', 'room_left', 'reconnected', 'room_joined',
                                                'player_joined', 'player_left', 'player_reconnected', 'spectator_joined', 'new_peer'})

    def test_late_sdk_errors_require_the_exact_failure_boundary(self):
        for kind, error in probe.LATE_ERRORS.items():
            result = {'players': 8, 'stage': 'gameplay', 'errors': [error], 'binary_receives': 1,
                      'control': kind, 'control_injected': True}
            output = 'LIVE_RELAY_FAILED ' + json.dumps(result)
            self.assertEqual(probe.validate_late_error(1, output, kind), result)
            for field, value in [('players', 2), ('stage', 'handshake'), ('errors', []),
                                 ('binary_receives', 0), ('control', 'unknown'), ('control_injected', False)]:
                changed = copy.deepcopy(result)
                changed[field] = value
                with self.subTest(kind=kind, field=field), self.assertRaises(ValueError):
                    probe.validate_late_error(1, 'LIVE_RELAY_FAILED ' + json.dumps(changed), kind)
            for code, text in [(0, output), (1, ''), (1, output + '\n' + output), (1, output + '\n' + probe.MARKER + '{}')]:
                with self.assertRaises(ValueError):
                    probe.validate_late_error(code, text, kind)

    def test_gameplay_inventory_is_required(self):
        result = {'passed': True, 'binary_receives': 1, 'records': [
            {'players': count, 'frames_submitted': 40, 'canonical_comparisons': 38 * count, 'minimum_confirmed': 38}
            for count in (2, 4, 8)]}
        encode = lambda value: probe.MARKER + json.dumps(value)
        self.assertEqual(probe.validate_result(encode(result)), result)
        mutations = []
        for field, value in [('passed', False), ('binary_receives', 0), ('binary_receives', True)]:
            changed = copy.deepcopy(result)
            changed[field] = value
            mutations.append(changed)
        changed = copy.deepcopy(result)
        changed['records'].pop()
        mutations.append(changed)
        for field, value in [('players', 3), ('frames_submitted', True), ('canonical_comparisons', 75), ('minimum_confirmed', 37)]:
            changed = copy.deepcopy(result)
            changed['records'][0][field] = value
            mutations.append(changed)
        for changed in mutations:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                probe.validate_result(encode(changed))
        for output in ('', encode(result) + '\n' + encode(result)):
            with self.assertRaises(ValueError):
                probe.validate_result(output)

    def test_build_receipt_binds_success_source_binary_and_commands(self):
        revision, digest = 'a' * 40, 'b' * 64
        source = {'Cargo.toml': 'c' * 64}
        build = {'format': 1, 'passed': True, 'source_revision': revision, 'source_inventory': source,
                 'binary_sha256': digest, 'exit_codes': [0, 0], 'tool_sha256': {'cargo': 'd' * 64, 'rustc': 'e' * 64},
                 'commands': [['/toolchain/cargo', 'clean', '-p', 'signal-fish-server'],
                              ['/toolchain/cargo', 'build', '--locked', '--no-default-features', '--bin', 'signal-fish-server']]}
        inputs = {name: 'f' * 64 for name in ('builder', 'fetch', 'pins', 'run', 'native_launcher', 'sdk_launcher', 'archive', 'cargo', 'rustc')}
        inputs.update(cargo='d' * 64, rustc='e' * 64)
        log_digest = '1' * 64
        build.update(binary='/build/server', builder_sha256=inputs['builder'], server_archive_sha256=inputs['archive'],
                     input_inventory=inputs, log_sha256=log_digest)
        self.assertEqual(str(probe.validate_build_receipt(build, revision, source, digest, inputs, log_digest)), '/toolchain/cargo')
        for field, value in [('passed', False), ('format', True), ('source_revision', 'f' * 40),
                             ('source_inventory', {}), ('binary_sha256', '0' * 64), ('exit_codes', [False, 0]),
                             ('exit_codes', [0, 1]), ('tool_sha256', {'cargo': 'd' * 64}), ('commands', [])]:
            changed = copy.deepcopy(build)
            changed[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                probe.validate_build_receipt(changed, revision, source, digest, inputs, log_digest)
        changed = copy.deepcopy(build)
        changed['commands'][1].remove('--locked')
        with self.assertRaises(ValueError):
            probe.validate_build_receipt(changed, revision, source, digest, inputs, log_digest)

    def test_build_provenance_fields_are_required(self):
        revision, digest = 'a' * 40, 'b' * 64
        source = {'Cargo.toml': 'c' * 64}
        inputs = {name: 'f' * 64 for name in ('builder', 'fetch', 'pins', 'run', 'native_launcher', 'sdk_launcher', 'archive', 'cargo', 'rustc')}
        inputs.update(cargo='d' * 64, rustc='e' * 64)
        log_digest = '1' * 64
        build = {'format': 1, 'passed': True, 'source_revision': revision, 'source_inventory': source,
                 'binary': '/build/server', 'binary_sha256': digest, 'exit_codes': [0, 0],
                 'tool_sha256': {'cargo': inputs['cargo'], 'rustc': inputs['rustc']},
                 'commands': [['/toolchain/cargo', 'clean', '-p', 'signal-fish-server'],
                              ['/toolchain/cargo', 'build', '--locked', '--no-default-features', '--bin', 'signal-fish-server']],
                 'builder_sha256': inputs['builder'], 'server_archive_sha256': inputs['archive'],
                 'input_inventory': inputs, 'log_sha256': log_digest}
        for field in ('builder_sha256', 'server_archive_sha256', 'input_inventory', 'log_sha256'):
            changed = copy.deepcopy(build)
            del changed[field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                probe.validate_build_receipt(changed, revision, source, digest, inputs, log_digest)
        for field, value in [('builder_sha256', '0' * 64), ('server_archive_sha256', '0' * 64),
                             ('log_sha256', '0' * 64), ('input_inventory', {}), ('input_inventory', list(inputs))]:
            changed = copy.deepcopy(build)
            changed[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                probe.validate_build_receipt(changed, revision, source, digest, inputs, log_digest)
        for name in inputs:
            changed = copy.deepcopy(build)
            changed['input_inventory'][name] = '0' * 64
            with self.subTest(input=name), self.assertRaises(ValueError):
                probe.validate_build_receipt(changed, revision, source, digest, inputs, log_digest)
        changed = copy.deepcopy(build)
        changed['input_inventory']['unknown'] = '0' * 64
        with self.assertRaises(ValueError):
            probe.validate_build_receipt(changed, revision, source, digest, inputs, log_digest)

    def test_known_build_log_rejects_symlink_directory_and_pipe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / 'build.log'
            log.write_bytes(b'completed build\n')
            self.assertEqual(probe.build_log_digest(log), hashlib.sha256(log.read_bytes()).hexdigest())
            target = root / 'other.log'
            log.rename(target)
            log.symlink_to(target)
            with self.assertRaisesRegex(ValueError, 'regular file'):
                probe.build_log_digest(log)
            log.unlink()
            log.mkdir()
            with self.assertRaisesRegex(ValueError, 'regular file'):
                probe.build_log_digest(log)
            log.rmdir()
            os.mkfifo(log)
            with self.assertRaisesRegex(ValueError, 'regular file'):
                probe.build_log_digest(log)


if __name__ == '__main__':
    unittest.main()
