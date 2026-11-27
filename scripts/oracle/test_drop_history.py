"""Validate the raw drop fields that distinguish the two source revisions."""
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
import tomllib
import unittest
from unittest.mock import patch

from drop_history_contract import check_checksum_reports, check_source_content, check_source_operation


class DropHistoryWireTests(unittest.TestCase):
    # Value: protects=real Cargo manifest parsing; fails_when=absolute path emits JSON surrogate escapes; why_new=alternate source stages a manifest; seam=build
    def test_candidate_manifest_uses_relative_dependency_under_a_unicode_checkout(self):
        import drop_history_launch as launch

        with TemporaryDirectory(prefix='drop-🌐-') as temporary:
            root = Path(temporary).resolve()
            cache = root / '.cache/reference'
            candidate = cache / 'drop-source-candidate/fortress-rollback-candidate'
            candidate.mkdir(parents=True)
            oracle = root / 'scripts/oracle/rust'
            (oracle / 'src').mkdir(parents=True)
            (oracle / 'Cargo.lock').write_text('')
            (oracle / 'Cargo.toml').write_text(
                '[dependencies]\nfortress-rollback = { path = "../../../.cache/reference/fortress-reviewed" }\n')

            def verify_manifest(command, *_args):
                path = Path(command[command.index('--manifest-path') + 1])
                value = tomllib.loads(path.read_text())['dependencies']['fortress-rollback']['path']
                self.assertEqual((path.parent / value).resolve(), candidate)

            tools = {'cargo': Path('cargo'), 'rustc': Path('rustc')}
            with patch.multiple(launch, ROOT=root, CACHE=cache), patch.object(launch, 'build', side_effect=verify_manifest) as build:
                launch.build_observer(tools, root, 'fortress-reviewed', candidate, 'candidate', True)
            build.assert_called_once()

    # Value: protects=exact operation and donor evidence; fails_when=version-6 identity projects away; why_new=version-2 lacks these fields; seam=none
    def test_operation_and_forwarded_donor_are_versioned(self):
        old = {'coordinator': 0, 'coordinator_generation': 0, 'sequence': 1, 'target_set_digest': 10167666227858214167}
        new = dict(old, participant_set_digest=5558023030422843596, terminal_epoch=0)
        check_source_operation(old, 'operation', 1, 2)
        check_source_operation(new, 'operation', 1, 6)
        for operation, wire in ((old, 6), (new, 2)):
            with self.assertRaisesRegex(ValueError, 'operation schema'):
                check_source_operation(operation, 'operation', 1, wire)
        for field, value in [('participant_set_digest', 0), ('terminal_epoch', False), ('terminal_epoch', 1)]:
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'operation ' + field):
                check_source_operation(dict(new, **{field: value}), 'operation', 1, 6)

        backfill = dict(operation=new, chunk_index=0, chunk_count=1, start_frame=259, frame_count=1, bytes=[1, 2, 3, 4],
                        donor=1, range_start=259)
        check_source_content('DropBackfill', backfill, 'backfill', 1, 1, warmup=251, wire=6)
        for field, value in [('donor', 0), ('range_start', 8), ('range_start', 259.0)]:
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'backfill ' + field):
                check_source_content('DropBackfill', dict(backfill, **{field: value}), 'backfill', 1, 1, warmup=251, wire=6)

    # Value: protects=complete post-cut basis evidence; fails_when=zero, wrong epoch, or truncated direction passes; why_new=only candidate reports basis; seam=none
    def test_checksum_basis_uses_exact_cut_and_per_route_frontier(self):
        packets = []
        token = 4176669562639073937
        for sender, last in enumerate((18, 18, 4)):
            for receiver in range(3):
                if receiver == sender:
                    continue
                for frame in range(1, last + 1):
                    report = {'frame': frame, 'checksum': 0, 'basis_token': token if frame > 8 else 0}
                    packets.append({'from': sender, 'to': str(receiver), 'raw': {
                        'header': {'conn_id': (3955875504, 1183501648, 748250720)[sender], 'flags': 0, 'protocol_version': 6, 'sentinel': [245, 82]},
                        'body': {'ChecksumReport': report}}})
        check_checksum_reports(packets, 8, 1, 0, 6)
        with self.assertRaisesRegex(ValueError, 'complete routes'):
            check_checksum_reports(packets[:-1], 8, 1, 0, 6)
        mutant = deepcopy(packets)
        mutant[7]['raw']['body']['ChecksumReport']['basis_token'] = token
        with self.assertRaisesRegex(ValueError, 'freeze basis'):
            check_checksum_reports(mutant, 8, 1, 0, 6)
        mutant[7]['raw']['body']['ChecksumReport']['basis_token'] = 0
        mutant[8]['raw']['body']['ChecksumReport']['basis_token'] = float(token)
        with self.assertRaisesRegex(ValueError, 'checksum basis token'):
            check_checksum_reports(mutant, 8, 1, 0, 6)


if __name__ == '__main__':
    unittest.main()
