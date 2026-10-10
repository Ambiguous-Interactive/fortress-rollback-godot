"""Value: ownership receipts reject incomplete, divergent or unrelated failure streams."""
import copy
import unittest

import ownership_probes as probes


def result():
    records = []
    for suite, names in probes.EXPECTED.items():
        for name in sorted(names):
            records.append({'suite': suite, 'case': name, 'category': 'determinism', 'seed': '1701',
                            'runs': [{'assertions': 1, 'failures': [], 'states': []} for _ in range(2)]})
    return {'format': 1, 'complete': True, 'count': probes.EXPECTED_COUNT,
            'errors': [], 'passed': True, 'records': records}


class OwnershipReceiptTests(unittest.TestCase):
    def test_complete_inventory(self):
        self.assertEqual(probes.validate(result(), False)['count'], probes.EXPECTED_COUNT)

    def test_missing_or_duplicate_inventory(self):
        for mutation in ('missing', 'duplicate'):
            with self.subTest(mutation=mutation):
                value = result()
                if mutation == 'missing':
                    value['records'].pop()
                else:
                    value['records'][-1] = copy.deepcopy(value['records'][0])
                with self.assertRaises(ValueError):
                    probes.validate(value, False)

    def test_incomplete_zero_assertions_and_divergence(self):
        for mutation in ('incomplete', 'zero', 'divergence'):
            with self.subTest(mutation=mutation):
                value = result()
                if mutation == 'incomplete':
                    value['complete'] = False
                elif mutation == 'zero':
                    for repetition in value['records'][0]['runs']:
                        repetition['assertions'] = 0
                else:
                    value['records'][0]['runs'][1]['states'] = [{'frame': 0, 'bytes': '09'}]
                with self.assertRaises(ValueError):
                    probes.validate(value, False)

    def test_schema_mutations(self):
        mutations = {
            'missing_errors': lambda value: value.pop('errors'),
            'errors_none': lambda value: value.update(errors=None),
            'records_dict': lambda value: value.update(records={}),
            'passed_integer': lambda value: value.update(passed=1),
            'assertions_boolean': lambda value: value['records'][0]['runs'][0].update(assertions=True),
            'runs_dict': lambda value: value['records'][0].update(runs={}),
            'states_none': lambda value: value['records'][0]['runs'][0].update(states=None),
            'failures_dict': lambda value: value['records'][0]['runs'][0].update(failures={}),
            'state_scalar': lambda value: value['records'][0]['runs'][0].update(states=[0]),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                value = result()
                mutate(value)
                with self.assertRaises(ValueError):
                    probes.validate(value, False)

    def test_negative_control_requires_exact_failures(self):
        value = result()
        value['passed'] = False
        with self.assertRaises(ValueError):
            probes.validate(value, True)
        failures = [{'label': label, 'kind': 'bytes', 'frame': 0, 'byte': 0, 'expected': '0100', 'actual': '0909'} for label in (
            'copied submission survives caller mutation', 'callback copy cannot edit history')]
        record = next(r for r in value['records'] if r['case'] == 'owned_input')
        for repetition in record['runs']:
            repetition['failures'] = copy.deepcopy(failures)
        self.assertFalse(probes.validate(value, True)['passed'])
        for repetition in record['runs']:
            repetition['failures'][0]['label'] = 'unexpected failure'
        with self.assertRaises(ValueError):
            probes.validate(value, True)


if __name__ == '__main__':
    unittest.main()
