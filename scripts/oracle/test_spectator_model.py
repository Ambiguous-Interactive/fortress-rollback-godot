"""Independent controls: the spectator model gate rejects corrupted or unverified evidence.

These are offline: they exercise the pure mutation, configuration and outcome
logic without Java or the fetched upstream tree. The TLC run itself is gated by
the launcher in the oracles CI job.
"""
import unittest

import spectator_model as model


class SpectatorModelTests(unittest.TestCase):
    SPEC_SAMPLE = 'Preceding.\n' + model.MUTANT_BEFORE + '\nFollowing.\n'

    # Value: protects=the mutant removes exactly the two safety guards; fails_when=the anchor moves
    # or the mutation keeps a guard; why_new=a silent no-op would verify nothing; seam=none
    def test_mutant_removes_both_guards(self):
        mutated = model.mutate(self.SPEC_SAMPLE)
        self.assertIn('AdvanceFrameNormal ==', mutated)
        self.assertNotIn('currentFrame < lastRecvFrame', mutated)
        self.assertNotIn('inputFrames[idx] = nextFrame', mutated)
        self.assertTrue(mutated.startswith('Preceding.'))
        self.assertTrue(mutated.endswith('Following.\n'))

    # Value: protects=an absent or duplicated anchor fails closed; fails_when=a renamed upstream action is
    # mutated blindly; why_new=a partial replace would test nothing; seam=none
    def test_mutant_anchor_fails_closed(self):
        for source in ('AdvanceFrameNormal ==\n    /\\ sessionState = "Running"\n',
                       self.SPEC_SAMPLE + model.MUTANT_BEFORE):
            with self.assertRaisesRegex(ValueError, 'mutant anchor'):
                model.mutate(source)

    # Value: protects=the required invariants stay configured; fails_when=the pinned cfg drops a
    # checked invariant; why_new=an invariant removed from cfg would pass silently; seam=none
    def test_config_validation_rejects_dropped_invariant(self):
        model.validate_config(''.join(f'INVARIANT {name}\n' for name in model.REQUIRED_INVARIANTS))
        for name in model.REQUIRED_INVARIANTS:
            kept = [other for other in model.REQUIRED_INVARIANTS if other != name]
            with self.assertRaisesRegex(ValueError, name):
                model.validate_config(''.join(f'INVARIANT {other}\n' for other in kept))

    # Value: protects=TLC outcomes are read strictly; fails_when=a surviving mutant or a failed
    # verification slips through; why_new=the positive/negative pair is the whole gate; seam=none
    def test_outcome_reading(self):
        verified = model._read_outcome(0, 'Model checking completed. No error has been found.', 'pinned', True)
        self.assertEqual(verified, {'returncode': 0, 'verified': True})
        for code, log in ((1, 'Model checking completed. No error has been found.'),
                          (0, 'Error: Invariant X is violated.')):
            with self.assertRaisesRegex(ValueError, 'pinned SpectatorSession model did not verify'):
                model._read_outcome(code, log, 'pinned', True)
        rejected = model._read_outcome(12, 'Error: Invariant SpectatorFrameBounded is violated.', 'mutant', False)
        self.assertEqual(rejected['rejected'], True)
        self.assertIn('SpectatorFrameBounded', rejected['violation'])
        for code, log in ((0, 'Error: Invariant X is violated.'),
                          (12, 'Model checking completed. No error has been found.')):
            with self.assertRaisesRegex(ValueError, 'mutant'):
                model._read_outcome(code, log, 'mutant', False)

    # Value: protects=missing/garbage TLC jars fail closed; fails_when=a corrupt fixture is accepted or a valid one is refused; why_new=hash check guards reviewed bytes; seam=none
    def test_jar_verification(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            good = root / 'good.jar'
            good.write_bytes(b'reviewed bytes')
            corrupt = root / 'corrupt.jar'
            corrupt.write_bytes(b'other bytes')
            original_source, original_sha = model.JAR_SOURCE, model.JAR_SHA256
            try:
                model.JAR_SOURCE, model.JAR_SHA256 = good, model.digest(good)
                seeded = root / 'nested' / 'tla2tools.jar'
                model.ensure_jar(seeded)
                self.assertEqual(model.digest(seeded), model.JAR_SHA256)
                with self.assertRaisesRegex(ValueError, 'cached TLC artifact'):
                    model.ensure_jar(corrupt)
                model.JAR_SOURCE = corrupt
                with self.assertRaisesRegex(ValueError, 'repository TLC artifact'):
                    model.ensure_jar(good)
            finally:
                model.JAR_SOURCE, model.JAR_SHA256 = original_source, original_sha


if __name__ == '__main__':
    unittest.main()
