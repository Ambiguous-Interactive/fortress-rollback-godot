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
        # Every frame carries its own input digest, and the file carries no trailing anchor.
        self.assertEqual(len(replay_golden.v5()), 23 + 2 + text + 4 * 7 + 2 * 16 + 4 * 16)
        self.assertEqual(len(replay_golden.v4()), 23 + 2 + text + 4 * 5 + 2 * 16 + 4 * 16)
        self.assertEqual(replay_golden.v4()[23 + 2 + text + 4], 1)
        self.assertEqual(len(replay_golden.v3()), 23 + 2 + text + 4 * 5 + 2 * 16 + 16)
        self.assertEqual(replay_golden.v3()[-16:], replay_golden.digest(replay_golden.FRAMES[-1][0]))
        self.assertEqual(len(replay_golden.v2()), 23 + 2 + text + 4 * 5 + 2 * 16)

    def test_every_frame_carries_its_own_input_digest(self):
        """The independent generator writes the digest of each row next to that row."""
        data = replay_golden.v5()
        cursor = 23 + 2 + sum(1 + len(replay_golden.FIELDS[name]) for name in replay_golden.NAMES)
        for (row, flag, checksum), statuses in zip(replay_golden.FRAMES, replay_golden.fixture()['statuses']):
            cursor += len(row) + len(statuses) + 1 + (16 if flag == 1 else 0)
            self.assertEqual(data[cursor:cursor + 16], replay_golden.digest(row + bytes(statuses)))
            cursor += 16
        self.assertEqual(cursor, len(data))


if __name__ == '__main__':
    unittest.main()
