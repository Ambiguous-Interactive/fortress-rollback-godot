"""Value: detects inventory drift and false release coverage; seam=temporary tree."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("inventory", Path(__file__).with_name("inventory.py"))
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)
PIN = {"repository": "https://example.invalid/upstream", "revision": "a" * 40,
       "archive": {"digest": "b" * 64, "algorithm": "sha256", "url": "https://example.invalid/archive"}}


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.write("src/queue.rs", '#[cfg(feature = "hot-join")]\n#[test]\nfn edge() {}\n')
        self.write("Cargo.toml", '[features]\nhot-join = []\n')
        self.baseline = inventory.scan(self.root, PIN)
        self.ledger = inventory.new_ledger(self.baseline)

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def errors(self, release=False):
        return inventory.validate(self.ledger, inventory.scan(self.root, PIN), release)

    def test_reproducible_inventory_preserves_inline_tests_and_features(self):
        self.assertEqual(self.baseline, inventory.scan(self.root, PIN))
        self.assertEqual([], self.errors())
        record = next(r for r in self.baseline["records"] if r["path"] == "src/queue.rs")
        self.assertEqual({"test_attribute", "configuration_candidate", "rust_function_candidate"},
                         {m[0] for m in record["markers"]})
        self.assertEqual({"hot-join": []}, self.baseline["cargo_features"]["Cargo.toml"])
        self.assertEqual("pending", self.ledger["decisions"][record["id"]]["status"])
        self.assertEqual("B2", record["ownership"]["task"])

    def test_added_deleted_renamed_and_hidden_files_fail_drift_check(self):
        for mutation in ("added", "deleted", "renamed", "hidden"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    for path in self.baseline["files"]:
                        target = root / path
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes((self.root / path).read_bytes())
                    if mutation == "added":
                        (root / "unknown.extension").write_text("new source")
                    elif mutation == "hidden":
                        (root / ".new-asset").write_text("new source")
                    elif mutation == "deleted":
                        (root / "src/queue.rs").unlink()
                    else:
                        (root / "src/queue.rs").rename(root / "src/renamed.rs")
                    self.assertTrue(any("drift" in e for e in inventory.validate(
                        self.ledger, inventory.scan(root, PIN))))

    def test_inline_test_or_feature_edit_fails_even_with_same_paths(self):
        for text in ('#[test]\nfn newly_added_boundary() {}\n', '#[cfg(feature = "new")]\nfn existing() {}\n'):
            with self.subTest(text=text):
                self.write("src/queue.rs", text)
                errors = self.errors()
                self.assertTrue(any('"changed": ["src/queue.rs"]' in e for e in errors))

    def test_decisions_cannot_silently_drop_source_or_use_unknown_status(self):
        ledger = copy.deepcopy(self.ledger)
        ledger["decisions"].pop(next(iter(ledger["decisions"])))
        self.assertIn("Decision identities differ from discovered source families",
                      inventory.validate(ledger, self.baseline))
        for item in self.ledger["decisions"].values():
            item["status"] = "passed-upstream"
        self.assertTrue(any("Invalid status" in e for e in self.errors()))

    def test_pending_and_fake_covered_decisions_block_release(self):
        self.assertTrue(any("Unreviewed behavior" in e for e in self.errors(True)))
        for item in self.ledger["decisions"].values():
            item.update(status="covered", applicability="supported")
        errors = self.errors(True)
        self.assertTrue(any("lacks mapped port tests" in e for e in errors))
        self.assertTrue(any("Incomplete semantic audit" in e for e in errors))
        self.assertTrue(any("Missing reviewed applicability" in e for e in errors))

    def test_source_family_schema_cannot_be_made_release_ready_by_flags(self):
        self.ledger["semantic_audit_complete"] = True
        for item in self.ledger["decisions"].values():
            item.update(status="covered", applicability="supported", port_test_ids=["invented::test"],
                        review={"reviewer": "name", "evidence": "claim", "revision": "value"})
        self.assertTrue(any("certification is not implemented" in e for e in self.errors(True)))

    def test_runtime_and_failure_evidence_are_not_automatically_excluded(self):
        for path in ("loom-tests/tests/shared.rs", "specs/tla/DoubleFailureRelay_Witness.cfg",
                     "fuzz/fuzz_targets/codec.rs", "proptest-regressions/network/old.txt"):
            self.write(path, "Known failure / runtime-specific evidence")
        discovered = inventory.new_ledger(inventory.scan(self.root, PIN))
        for item in discovered["decisions"].values():
            self.assertEqual("pending", item["status"])
            self.assertEqual("unknown", item["applicability"])
            self.assertEqual([], item["port_test_ids"])

    def test_symlink_cannot_escape_source_manifest(self):
        (self.root / "outside").symlink_to(Path(__file__))
        with self.assertRaisesRegex(ValueError, "Symlink"):
            inventory.scan(self.root, PIN)

    def test_source_revision_and_marker_tampering_fail_verification(self):
        for key in ("source", "records"):
            with self.subTest(key=key):
                ledger = copy.deepcopy(self.ledger)
                ledger["inventory"][key] = {}
                self.assertTrue(inventory.validate(ledger, self.baseline))


class PortTestBindingTests(unittest.TestCase):
    """Value: coverage claims bind to executed passing evidence at one candidate commit."""

    SUITE = "res://tests/unit/test_online_lifecycle.gd"
    CASE = "saturated_handshake_expiry"
    COMMIT = "c" * 40
    PINS = "p" * 64

    def ledger_with(self, *test_ids):
        return {"schema_version": 1, "inventory": {"files": {}, "records": []},
                "decisions": {"fortress:src/queue.rs": dict(inventory.decision(), port_test_ids=list(test_ids))}}

    def bundle(self, commit=COMMIT, pins=PINS, suite=SUITE, case=CASE, **overrides):
        marker = {"format": 1, "passed": True, "complete": True,
                  "records": [{"suite": suite, "case": case}]}
        value = {"format": 1, "passed": True, "working_tree_dirty": False, "commit": commit,
                 "pin_manifest_sha256": pins, "engine": "4.3.stable.official", "platform": "Linux",
                 "machine": "arm64", "seed": "1701",
                 "runs": [{"command": ["godot", "--suite", suite], "exit": 0,
                           "stdout": inventory.RUN_MARKER + json.dumps(marker)}]}
        value.update(overrides)
        return value

    def bound_errors(self, ledger, bundles):
        return inventory.binding_errors(ledger, bundles, self.COMMIT, self.PINS)

    def test_valid_completed_coverage_passes_and_always_on_identities_stay_checked(self):
        ledger = self.ledger_with(f"{self.SUITE}::{self.CASE}")
        self.assertEqual([], self.bound_errors(ledger, [self.bundle()]))
        self.assertEqual([], inventory.binding_errors(ledger, [self.bundle(), self.bundle(case="pressured_handshake_expiry")],
                                                      self.COMMIT, self.PINS))
        discovered = {"files": {}, "records": [{"id": "fortress:src/queue.rs"}]}
        bound = self.ledger_with(self.SUITE)
        broken = self.ledger_with("invented::test", "res://tests/unit/missing_suite.gd")
        bound["inventory"] = broken["inventory"] = discovered
        self.assertEqual([], inventory.validate(bound, discovered))
        errors = inventory.validate(broken, discovered)
        self.assertTrue(any("unparseable port test identity" in e for e in errors))
        self.assertTrue(any("names a missing repository file" in e for e in errors))

    def test_binding_rejects_each_broken_evidence_shape_for_its_reason(self):
        ledger = self.ledger_with(f"{self.SUITE}::{self.CASE}")
        failed_marker = {"format": 1, "passed": False, "complete": True, "records": [{"suite": self.SUITE, "case": self.CASE}]}
        incomplete_marker = {"format": 1, "passed": True, "complete": False, "records": [{"suite": self.SUITE, "case": self.CASE}]}
        run = lambda stdout, exit_code=0: [{"command": ["godot", "--suite", self.SUITE], "exit": exit_code, "stdout": stdout}]
        mutations = [
            ("stale commit", ledger, [self.bundle(commit="d" * 40)], "commit differs"),
            ("dirty tree", ledger, [self.bundle(working_tree_dirty=True)], "dirty working tree"),
            ("stale pins", ledger, [self.bundle(pins="q" * 64)], "pin manifest digest differs"),
            ("failed run", ledger, [self.bundle(runs=run("", exit_code=1))], "failed or unbounded run"),
            ("no runs", ledger, [self.bundle(runs=[])], "records no executed run"),
            ("failed marker", ledger, [self.bundle(runs=run(inventory.RUN_MARKER + json.dumps(failed_marker)))], "failed or incomplete"),
            ("incomplete marker", ledger, [self.bundle(runs=run(inventory.RUN_MARKER + json.dumps(incomplete_marker)))], "failed or incomplete"),
            ("unparsable marker", ledger, [self.bundle(runs=run(inventory.RUN_MARKER + "{"))], "unparsable"),
            ("foreign case", ledger, [self.bundle(case="pressured_handshake_expiry")], "not executed and passed"),
            ("foreign suite", ledger, [self.bundle(suite=self.SUITE.replace("lifecycle", "handshake"))], "not executed and passed"),
            ("absent platform evidence", ledger, [self.bundle(engine=None)], "platform evidence is absent"),
            ("non-boolean pass", ledger, [self.bundle(passed=1)], "did not pass"),
            ("no bundles", ledger, [], "not executed and passed"),
            ("malformed run stdout", ledger, [self.bundle(runs=[{"command": ["godot"], "exit": 0, "stdout": 7}])], "run stdout is absent or malformed"),
        ]
        for name, bound, bundles, expected in mutations:
            with self.subTest(name=name):
                self.assertTrue(any(expected in e for e in self.bound_errors(bound, bundles)))

    def test_script_qualname_mapping_names_its_missing_receipt_bundle(self):
        ledger = self.ledger_with("scripts/oracle/spectator_runtime.py::check")
        errors = self.bound_errors(ledger, [self.bundle()])
        self.assertTrue(any("has no implemented receipt binding" in e for e in errors), errors)


if __name__ == "__main__":
    unittest.main()
