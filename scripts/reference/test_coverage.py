"""Value: ledger coverage claims certify executed evidence, never intent.

The verifier must pass one honestly produced bundle, and fail every hostile
shape issue #55 lists — forged test identities, a flipped audit-complete flag,
stale success JSON, partial completions, missing artifacts, unknown supported
behaviors, stale source revisions and ledger drift — for its specific reason.
"""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import coverage


REVISION = 'c' * 40
IDENTITY = 'res://tests/unit/test_input_endpoint.gd'


class CoverageVerifierTests(unittest.TestCase):
    def make_ledger(self, folder, decisions=None, audit_complete=False):
        ledger = {
            'schema_version': 1,
            'semantic_audit_complete': audit_complete,
            'inventory': {'source': {'repository': 'https://github.com/example/fortress',
                                     'revision': REVISION}},
            'decisions': decisions if decisions is not None else {
                'fortress:src/queue.rs': {'status': 'covered', 'applicability': 'applicable',
                                          'port_test_ids': [IDENTITY]},
                'fortress:src/idle.rs': {'status': 'pending', 'applicability': 'unknown',
                                         'port_test_ids': []},
            },
        }
        path = Path(folder) / 'ledger.json'
        path.write_text(json.dumps(ledger), encoding='utf-8')
        return path

    def make_bundle(self, folder, results=None, revision=REVISION, ledger_digest=None,
                    run_id=None, audit_complete=False, ledger_decisions=None):
        """Ledger + bundle + artifact store; the honest corpus by default."""
        ledger = self.make_ledger(folder, audit_complete=audit_complete, decisions=ledger_decisions)
        if results is None:
            results = [self.result()]
        bundle = {
            'schema_version': 1,
            'source_revision': revision,
            'ledger_sha256': ledger_digest or hashlib.sha256(ledger.read_bytes()).hexdigest(),
            'run_id': run_id or coverage.canonical_results_digest(results),
            'engine': '4.3.stable.official.77dcf97d8',
            'results': results,
        }
        bundle_path = Path(folder) / 'bundle.json'
        bundle_path.write_text(json.dumps(bundle), encoding='utf-8')
        artifacts = Path(folder) / 'artifacts'; artifacts.mkdir(exist_ok=True)
        artifact = artifacts / 'run-queue.json'
        artifact.write_text(json.dumps({'suite': 'queue', 'frames': 3}), encoding='utf-8')
        return ledger, bundle_path, artifacts

    @staticmethod
    def result(**overrides):
        artifact = overrides.pop('artifact_bytes', None)
        entry = {
            'test_id': IDENTITY, 'suite': 'tests/unit/test_input_endpoint.gd',
            'status': 'passed', 'complete': True, 'engine': '4.3.stable.official.77dcf97d8',
            'seed': 1234, 'artifact': 'run-queue.json', 'artifact_sha256': 'stale',
        }
        if artifact is not None:
            entry['artifact_sha256'] = hashlib.sha256(artifact).hexdigest()
        entry.update(overrides)
        return entry

    def verify(self, ledger, bundle, artifacts):
        return coverage.verify(ledger, bundle, artifacts)

    def test_honest_bundle_verifies(self):
        artifact = json.dumps({'suite': 'queue', 'frames': 3}).encode()
        with tempfile.TemporaryDirectory() as folder:
            ledger, bundle, artifacts = self.make_bundle(
                folder, results=[self.result(artifact_bytes=artifact)])
            verified, reasons, count = self.verify(ledger, bundle, artifacts)
            self.assertTrue(verified, reasons)
            self.assertEqual(reasons, [])
            self.assertEqual(count, 1)

    # Data-driven mutation table over issue #55's hostile shapes: each row
    # mutates exactly one evidence property and must fail for its own reason.
    def test_hostile_shapes_fail_for_their_specific_reason(self):
        artifact = json.dumps({'suite': 'queue', 'frames': 3}).encode()
        cases = [
            ('forged_test_id', {'results': [self.result(artifact_bytes=artifact, test_id='res://tests/unit/absent_suite.gd')]},
             'no executed result'),
            ('shared_forged_identity',
             {'results': [self.result(artifact_bytes=artifact, test_id='res://tests/unit/absent_suite.gd')],
              'ledger_decisions': {'fortress:src/queue.rs': {'status': 'covered', 'applicability': 'applicable',
                                                             'port_test_ids': ['res://tests/unit/absent_suite.gd']}}},
             'names a missing repository file'),
            ('failed_result', {'results': [self.result(artifact_bytes=artifact, status='failed')]},
             'never completed with a passing result'),
            ('partial_completion', {'results': [self.result(artifact_bytes=artifact, complete=False)]},
             'never completed with a passing result'),
            ('wrong_engine', {'results': [self.result(artifact_bytes=artifact, engine='4.7.2.stable')]},
             'gate declares'),
            ('missing_seed', {'results': [self.result(artifact_bytes=artifact, seed=None)]},
             'lacks seed evidence'),
            ('missing_artifact', {'results': [self.result(artifact='gone.json',
                                                          artifact_sha256=hashlib.sha256(b'x').hexdigest())]},
             'cites missing artifact'),
            ('stale_revision', {'revision': 'd' * 40}, 'ledger pins'),
            ('ledger_drift', {'ledger_digest': '0' * 64}, 'different parity ledger'),
            ('tampered_run_id', {'run_id': '0' * 64}, 'run identity does not match'),
            ('covered_without_applicability',
             {'ledger_decisions': {'fortress:src/queue.rs': {'status': 'covered', 'applicability': 'unknown',
                                                             'port_test_ids': ['queue_rolls_back']}}},
             'without applicable port-test identities'),
            ('malformed_identities',
             {'ledger_decisions': {'fortress:src/queue.rs': {'status': 'covered', 'applicability': 'applicable',
                                                             'port_test_ids': 'queue_rolls_back'}}},
             'without applicable port-test identities'),
            ('artifact_path_traversal',
             {'results': [self.result(artifact='../outside.json',
                                      artifact_sha256=hashlib.sha256(b'outside').hexdigest())]},
             'lacks artifact evidence'),
            ('conflicting_results',
             {'results': [self.result(artifact_bytes=artifact, status='failed', complete=True),
                          self.result(artifact_bytes=artifact)]},
             'conflicting results'),
            ('flipped_audit_flag',
             {'audit_complete': True,
              'ledger_decisions': {'fortress:src/idle.rs': {'status': 'pending', 'applicability': 'unknown',
                                                            'port_test_ids': []}}},
             'entirely pending ledger'),
            ('audit_flag_missing_coverage', {'audit_complete': True}, 'unverified coverage'),
        ]
        for name, options, reason in cases:
            with self.subTest(shape=name):
                with tempfile.TemporaryDirectory() as folder:
                    ledger, bundle, artifacts = self.make_bundle(folder, **options)
                    verified, reasons, _ = self.verify(ledger, bundle, artifacts)
                    self.assertFalse(verified, name)
                    self.assertTrue(any(reason in line for line in reasons),
                                    f'{name}: {reasons}')

    def test_audit_flag_with_results_outside_the_supported_set(self):
        artifact = json.dumps({'suite': 'queue', 'frames': 3}).encode()
        results = [self.result(artifact_bytes=artifact),
                   self.result(test_id='res://tests/unit/absent_suite.gd', artifact='none.json')]
        with tempfile.TemporaryDirectory() as folder:
            ledger, bundle, artifacts = self.make_bundle(
                folder, results=results, audit_complete=True,
                ledger_decisions={'fortress:src/queue.rs': {'status': 'covered', 'applicability': 'applicable',
                                                            'port_test_ids': [IDENTITY]},
                                  'fortress:src/idle.rs': {'status': 'covered', 'applicability': 'applicable',
                                                           'port_test_ids': ['res://tests/unit/test_session.gd']}})
            verified, reasons, _ = self.verify(ledger, bundle, artifacts)
            self.assertFalse(verified)
            self.assertTrue(any('outside the supported set' in line for line in reasons), reasons)
            self.assertTrue(any('test_session.gd' in line for line in reasons), reasons)

    def test_artifact_digest_drift_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            real = json.dumps({'suite': 'queue', 'frames': 3}).encode()
            results = [self.result(artifact_bytes=real, artifact_sha256=hashlib.sha256(b'other').hexdigest())]
            ledger, bundle, artifacts = self.make_bundle(folder, results=results)
            verified, reasons, _ = self.verify(ledger, bundle, artifacts)
            self.assertFalse(verified)
            self.assertTrue(any('digest drift' in line for line in reasons), reasons)

    def test_tooling_failures(self):
        with tempfile.TemporaryDirectory() as folder:
            ledger, bundle, artifacts = self.make_bundle(folder)
            for mutate, message in (
                (lambda path: path.write_text('{"schema_version": 2}', encoding='utf-8'), 'schema'),
                (lambda path: path.write_text('{"schema_version": 1}', encoding='utf-8'), 'run identity'),
                (lambda path: path.write_text('{"schema_version": 1, "run_id": "r", "results": ["x"]}',
                                              encoding='utf-8'), 'not an object'),
            ):
                original = bundle.read_text(encoding='utf-8')
                mutate(bundle)
                with self.assertRaises(ValueError, msg=message):
                    self.verify(ledger, bundle, artifacts)
                bundle.write_text(original, encoding='utf-8')
            # A missing evidence directory is an input failure, never a verdict.
            with self.assertRaises(ValueError):
                self.verify(ledger, bundle, Path(folder) / 'absent-artifacts')

    def test_malformed_covered_decision_without_identities_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            ledger, bundle, artifacts = self.make_bundle(
                folder, ledger_decisions={'fortress:src/queue.rs': {'status': 'covered',
                                                                    'applicability': 'applicable',
                                                                    'port_test_ids': []}})
            verified, reasons, _ = self.verify(ledger, bundle, artifacts)
            self.assertFalse(verified)
            self.assertTrue(any('without applicable port-test identities' in line for line in reasons), reasons)

    def test_main_exit_codes(self):
        artifact = json.dumps({'suite': 'queue', 'frames': 3}).encode()
        with tempfile.TemporaryDirectory() as folder:
            ledger, bundle, artifacts = self.make_bundle(
                folder, results=[self.result(artifact_bytes=artifact)])
            self.assertEqual(coverage.main_with_args(['--ledger', str(ledger), '--bundle', str(bundle),
                                                      '--artifacts', str(artifacts)]), 0)
            # Verification failure is exit 1; a missing evidence directory is a
            # tooling error and stays exit 2.
            stale = Path(folder) / 'stale.json'
            stale.write_text(bundle.read_text(encoding='utf-8').replace('"seed": 1234', '"seed": "late"'),
                             encoding='utf-8')
            self.assertEqual(coverage.main_with_args(['--ledger', str(ledger), '--bundle', str(stale),
                                                      '--artifacts', str(artifacts)]), 1)
            self.assertEqual(coverage.main_with_args(['--ledger', str(ledger), '--bundle', str(bundle),
                                                      '--artifacts', str(Path(folder) / 'absent')]), 2)
            self.assertEqual(coverage.main_with_args(['--ledger', str(ledger), '--bundle',
                                                      str(Path(folder) / 'absent.json'),
                                                      '--artifacts', str(artifacts)]), 2)


if __name__ == '__main__':
    unittest.main()
