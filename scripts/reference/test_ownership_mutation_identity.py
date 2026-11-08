"""Rejected ownership-run gates split from the original single suite for bounded parallel files."""

import ownership_probes as probes
from ownership_rejection_fixture import OwnershipRejectionFixture


class OwnershipMutationIdentityTests(OwnershipRejectionFixture):
    # Value: protects=verified runtime bytes before execution; fails_when=changes execute then fail only at publication;
    # why_new=after-use mutation tests establish rejection but not before-use gating; seam=mocked native/export boundaries
    def test_changed_runtime_or_export_never_executes(self):
        for selected in ('chromium', 'firefox'):
            for target in ('node', 'browser', 'package', 'export', 'source', 'display'):
                with self.subTest(selected=selected, target=target):
                    results = self.scenario(expected=ValueError, selected=selected, version='4.3', runtime_before=target)
                    self.assertFalse((results / 'ownership.json').exists())
                    self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')

    # Value: protects=extracted engine and Web templates at actual use; fails_when=verified installation mutates later;
    # why_new=browser tool hashes omit native/export tools; seam=mocked extraction/import/native/export boundaries
    def test_engine_and_template_mutations_stop_before_another_use(self):
        for selected in ('chromium', 'firefox'):
            for boundary in ('editor_freeze', 'import', 'native', 'template_freeze', 'export'):
                with self.subTest(selected=selected, boundary=boundary):
                    results = self.scenario(expected=ValueError, selected=selected, version='4.3', tool_fault=boundary)
                    self.assertFalse((results / 'ownership.json').exists())

    def test_runtime_or_export_mutation_cannot_qualify_either_browser(self):
        for selected in ('chromium', 'firefox'):
            for target in ('browser', 'package', 'export', 'source', 'display'):
                with self.subTest(selected=selected, target=target):
                    results = self.scenario(expected=ValueError, selected=selected, runtime_fault=target)
                    self.assertFalse((results / 'ownership.json').exists())
                    self.assertEqual(self.rounds(results)[0]['outcome'], 'failed')

    # Value: protects=staged executed bytes and imported metadata; fails_when=stage mutation publishes success;
    # why_new=root hashes and finished exports do not cover execution inputs; seam=mocked engine boundaries
    def test_staged_project_changes_cannot_publish_success(self):
        for selected in ('chromium', 'firefox'):
            for boundary in ('import', 'native', 'export', 'browser'):
                for mutation in ('source', 'delete', 'orphan', 'unknown', 'import'):
                    with self.subTest(selected=selected, boundary=boundary, mutation=mutation):
                        results = self.scenario(expected=ValueError, selected=selected, version='4.3', project_fault=(boundary, mutation))
                        self.assertFalse((results / 'ownership.json').exists())
            for boundary in ('native', 'export', 'browser'):
                with self.subTest(selected=selected, boundary=boundary, mutation='metadata'):
                    results = self.scenario(expected=ValueError, selected=selected, version='4.3', project_fault=(boundary, 'metadata'))
                    self.assertFalse((results / 'ownership.json').exists())

