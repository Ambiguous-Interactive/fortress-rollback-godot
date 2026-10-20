"""Value: detects a hand-edited or stale replay golden; seam=none."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("replay_golden", Path(__file__).with_name("replay_golden.py"))
replay_golden = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(replay_golden)


class ReplayGoldenTests(unittest.TestCase):
    def test_checked_in_golden_matches_generator(self):
        self.assertEqual(replay_golden.DESTINATION.read_bytes(), replay_golden.rendered())

    def test_layout_sizes(self):
        text = sum(1 + len(replay_golden.FIELDS[name]) for name in
                   ['engine_version', 'addon_version', 'upstream_revision', 'game_seed', 'game_version'])
        self.assertEqual(len(replay_golden.v3()), 23 + 2 + text + 4 * 5 + 2 * 16 + 16)
        self.assertEqual(replay_golden.v3()[23 + 2 + text + 4], 1)
        self.assertEqual(replay_golden.v3()[-16:], replay_golden.digest(replay_golden.FRAMES[-1][0]))
        self.assertEqual(len(replay_golden.v2()), 23 + 2 + text + 4 * 5 + 2 * 16)


if __name__ == '__main__':
    unittest.main()
