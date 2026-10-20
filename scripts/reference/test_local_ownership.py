"""Value: one local run at a time owns the shared reference paths.

Two local probes that share `.cache/reference/` delete each other's
logs, write the same project and export trees, and starve each other of
CPU. These tests pin the ownership rule:

* a claim is exclusive, and a second run is told who holds it;
* a claim waits for a short time and then succeeds;
* a released claim can be taken again;
* different resources never block each other.
"""

import json
import tempfile
import threading
import time
import unittest
from pathlib import Path

import local_ownership


class ClaimTest(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())

    def claim(self, resource='ownership', timeout=0.0):
        return local_ownership.claim(resource, timeout=timeout, directory=self.directory)

    def test_a_claim_is_exclusive_and_names_the_holder(self):
        with self.claim():
            with self.assertRaises(ValueError) as error:
                self.claim()
            self.assertIn('owned by another local run', str(error.exception))
            self.assertIn('ownership', str(error.exception))

    def test_a_released_claim_can_be_taken_again(self):
        self.claim().release()
        with self.claim():
            pass

    def test_a_claim_waits_for_the_holder(self):
        def holder():
            time.sleep(0.6)
            with self.claim():
                pass

        thread = threading.Thread(target=holder)
        thread.start()
        with self.claim(timeout=5.0):
            pass
        thread.join()

    def test_different_resources_do_not_block_each_other(self):
        with self.claim('ownership'):
            with self.claim('relay'):
                pass

    def test_the_holder_is_recorded_for_the_next_reader(self):
        with self.claim():
            record = json.loads((self.directory / 'ownership.lock').read_text(encoding='utf-8'))
            self.assertIn('pid', record)
            self.assertIn('command', record)
            self.assertFalse(record['released'])

    def test_a_release_marks_the_holder_as_gone(self):
        self.claim().release()
        record = json.loads((self.directory / 'ownership.lock').read_text(encoding='utf-8'))
        self.assertTrue(record['released'])


if __name__ == '__main__':
    unittest.main()
