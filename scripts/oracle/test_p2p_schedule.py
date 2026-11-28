"""A schedule hint can supply only observations already emitted on this upstream run."""
from copy import deepcopy
import json
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

import p2p_schedule


class ScheduleHintTests(unittest.TestCase):
    # Value: protects=qualification reuses schedules; fails_when=a pin or generator invalidates the bundle; why_new=other cases use synthetic fingerprints; seam=none
    def test_tracked_hints_cover_the_current_corpus(self):
        from p2p_launch import case_names, p2p_lifecycle_corpus

        hints = p2p_schedule.schedule_hints()
        self.assertCountEqual(
            hints, [*case_names(), *p2p_lifecycle_corpus.NAMES],
            'Regenerate with python3 scripts/oracle/p2p_schedule.py --binary .cache/reference/target/debug/p2p '
            'after building the P2P observer against the selected pin.')

    # Value: protects=hint reuse across SignalFish upgrades; fails_when=unrelated pins invalidate hints; why_new=prefix tests omit input identity; seam=none
    def test_hint_identity_tracks_p2p_generation_inputs(self):
        root = p2p_schedule.HINTS.parents[3]
        with TemporaryDirectory() as temporary:
            checkout = Path(temporary)
            oracle = checkout / 'scripts/oracle'
            shutil.copytree(root / 'scripts/oracle', oracle, ignore=shutil.ignore_patterns('__pycache__', 'fixtures', 'tools', 'target'))
            (oracle / 'fixtures').mkdir()
            pins = checkout / 'docs/reference/pins.json'
            pins.parent.mkdir(parents=True)
            manifest = json.loads((root / 'docs/reference/pins.json').read_text(encoding='utf-8'))
            pins.write_text(json.dumps(manifest), encoding='utf-8')
            cases = {'mesh_2_delay_0': {'players': 2, 'operations': []}}
            with patch.object(p2p_schedule, 'HINTS', oracle / 'fixtures/p2p-schedules.json.gz'):
                p2p_schedule.write_hints(cases)
                self.assertEqual(p2p_schedule.schedule_hints(), cases)
                for name in ('sdk', 'server', 'fortress'):
                    with self.subTest(source=name):
                        changed = deepcopy(manifest)
                        source = changed['sources'][name]
                        revision = '1' * 40
                        source['archive']['url'] = source['archive']['url'].replace(source['revision'], revision)
                        source['root'] = source['root'].replace(source['revision'], revision)
                        source['revision'] = revision
                        if name != 'fortress':
                            source['archive']['digest'] = '2' * 64
                        pins.write_text(json.dumps(changed), encoding='utf-8')
                        self.assertEqual(p2p_schedule.schedule_hints(), {} if name == 'fortress' else cases)
                for path, replacement in ((('archive', 'digest'), '3' * 64), (('repository',), 'https://github.com/example/fortress-rollback')):
                    with self.subTest(fortress_pin=path):
                        changed = deepcopy(manifest)
                        source = changed['sources']['fortress']
                        for key in path[:-1]:
                            source = source[key]
                        source[path[-1]] = replacement
                        pins.write_text(json.dumps(changed), encoding='utf-8')
                        self.assertEqual(p2p_schedule.schedule_hints(), {})
                changed = deepcopy(manifest)
                changed['rust']['version'] += '-changed'
                pins.write_text(json.dumps(changed), encoding='utf-8')
                self.assertEqual(p2p_schedule.schedule_hints(), {})
                pins.write_text(json.dumps(manifest), encoding='utf-8')
                for name in ('p2p_lifecycle_corpus.py', 'rust/src/bin/p2p.rs', 'rust/Cargo.toml', 'rust/Cargo.lock'):
                    with self.subTest(generator=name):
                        path = oracle / name
                        original = path.read_bytes()
                        path.write_bytes(original + b'\n')
                        actual = p2p_schedule.schedule_hints()
                        path.write_bytes(original)
                        self.assertEqual(actual, {})
                self.assertEqual(p2p_schedule.schedule_hints(), cases)

    def test_prefix_excludes_later_outputs_and_divergent_operations_use_real_oracle(self):
        ops = [{'n': n} for n in range(3)]
        hint = {'players': 2, 'operations': ops}
        trace = {'records': [{'outgoing': [0, 1]}, {'outgoing': []}, {'outgoing': [2]}], 'packets': ['a', 'b', 'c']}
        observe = Mock(side_effect=[trace, 'changed operation', 'changed settings', 'other executable'])
        lookup = p2p_schedule.builder_observer('binary', hint, observe)
        for length in (1, 2, 3):
            partial = {**hint, 'operations': ops[:length]}
            actual = lookup('binary', partial)
            self.assertEqual(actual['records'], trace['records'][:length])
            self.assertEqual(actual['packets'], ['a', 'b'] if length < 3 else trace['packets'])
            self.assertEqual(actual['scenario'], partial)
        observe.assert_called_once_with('binary', hint)
        self.assertEqual(lookup('binary', {**hint, 'operations': [{'n': 9}]}), 'changed operation')
        self.assertEqual(lookup('binary', {**hint, 'players': 3}), 'changed settings')
        self.assertEqual(lookup('other', hint), 'other executable')
        self.assertIs(p2p_schedule.builder_observer('binary', None, observe), observe)
