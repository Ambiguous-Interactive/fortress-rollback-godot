"""Value: rejects false queue parity; existing replay tests never execute a Godot queue; no test seam."""
import copy
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch
from queue_launch import observation_source, OBSERVATION_HOOK
from queue_contract import validate_bundle, compare


class QueueContractTests(unittest.TestCase):
    def test_bundle_mutations(self):
        valid = {'format': 1, 'upstream_revision': 'f13cd5c0f2815926785a395947e18da0dbea0dd8', 'cases': [
            {'name': 'small', 'capacity': 2, 'input_width': 1, 'player': 0, 'operations': [{'kind': 'add', 'frame': 0, 'bytes': '01'}]}]}
        self.assertEqual(validate_bundle(valid), valid)
        mutations = [('format', True), ('format', 2), ('upstream_revision', 'stale'), ('cases', []), ('unknown', 1)]
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                bad = copy.deepcopy(valid)
                bad[key] = value
                with self.assertRaises(ValueError):
                    validate_bundle(bad)
        for key, value in [('capacity', 1), ('input_width', 33), ('player', 8), ('operations', []), ('capacity', 2.0)]:
            with self.subTest(key=key, value=value):
                bad = copy.deepcopy(valid)
                bad['cases'][0][key] = value
                with self.assertRaises(ValueError):
                    validate_bundle(bad)
        for bad_op in [{'kind': 'read', 'frame': True}, {'kind': 'add', 'frame': 0, 'bytes': 'FF'},
                       {'kind': 'add_reclaim', 'frame': 0, 'bytes': '01', 'floor': True},
                       {'kind': 'delay_reclaim', 'value': 1, 'floor': -1}, {'kind': 'retained', 'frame': 1.0},
                       {'kind': 'reset', 'extra': 1}, {'kind': 'unknown'}, {'kind': 'read', 'frame': -1}]:
            with self.subTest(operation=bad_op):
                bad = copy.deepcopy(valid)
                bad['cases'][0]['operations'] = [bad_op]
                with self.assertRaises(ValueError):
                    validate_bundle(bad)

    def test_observation_hook_preserves_original_and_replaces_stale_copy(self):
        # The observed crate must come from fresh pinned bytes, never an old altered hook.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'pinned'
            (source / 'src/input_queue').mkdir(parents=True)
            original = b'// immutable source\n'
            (source / 'src/input_queue/mod.rs').write_bytes(original)
            with patch('queue_launch.CACHE', root / 'cache'):
                _, receipt = observation_source(source)
                hooked = root / 'cache/queue-observation/fortress/src/input_queue/mod.rs'
                self.assertEqual(hooked.read_bytes(), original + OBSERVATION_HOOK.encode())
                hooked.write_text('altered wrapper')
                _, repeated = observation_source(source)
                self.assertEqual(receipt, repeated)
                self.assertEqual(hooked.read_bytes(), original + OBSERVATION_HOOK.encode())
                self.assertEqual((source / 'src/input_queue/mod.rs').read_bytes(), original)
                self.assertTrue(receipt['original_queue_unmodified'])

    def test_first_divergence_and_complete_consumption(self):
        record = {'index': 0, 'kind': 'read', 'accepted': True, 'frame': 0, 'bytes': '01',
                  'status': 'predicted', 'first_incorrect': -1, 'delay': 0}
        trace = {'format': 1, 'upstream_revision': 'f13cd5c0f2815926785a395947e18da0dbea0dd8',
                 'complete': True, 'cases': [{'name': 'small', 'records': [record]}]}
        compare(trace, copy.deepcopy(trace), ['small'], [1])
        for key, value in [('frame', 1), ('bytes', '02'), ('status', 'confirmed'), ('first_incorrect', 0),
                           ('accepted', 1), ('delay', True), ('index', 1), ('kind', 'confirmed')]:
            bad = copy.deepcopy(trace)
            bad['cases'][0]['records'][0][key] = value
            with self.subTest(key=key):
                with self.assertRaisesRegex(ValueError, 'small.*operation 0'):
                    compare(trace, bad, ['small'], [1])
        for mutate in (lambda x: x['cases'][0]['records'].clear(), lambda x: x['cases'].clear(),
                       lambda x: x.update(complete=False), lambda x: x.update(format=True)):
            bad = copy.deepcopy(trace)
            mutate(bad)
            with self.assertRaises(ValueError):
                compare(trace, bad, ['small'], [1])


if __name__ == '__main__':
    unittest.main()
