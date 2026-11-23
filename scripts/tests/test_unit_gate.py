"""The stable verdict requires both fresh processes, every assigned case and the candidate's source and engine bytes."""
import copy
import json
from pathlib import Path
import platform
import tempfile
import unittest
from unittest import mock

import unit_gate as gate


class UnitGateTests(unittest.TestCase):
    def test_literal_inventory_requires_the_entire_method(self):
        header = "func cases() -> PackedStringArray:\n"
        self.assertEqual(gate.literal_cases(header + ' return PackedStringArray(\n ["one", "two",]\n )'), ["one", "two"])
        for body in (' return NAMES', ' if OS.is_debug_build():\n  return PackedStringArray(["one"])\n return PackedStringArray(["two"])',
                     ' return PackedStringArray(["duplicate", "duplicate"])'):
            self.assertIsNone(gate.literal_cases(header + body))

    def test_balancing_and_missing_timing_hints(self):
        suites = list("abcdefg")
        weights = dict(zip(suites, [200, 200, 200, 20, 20, 20, 20]))
        rows = gate.partitions(suites, weights)
        self.assertEqual(len(rows), 3)
        self.assertCountEqual([s for row in rows for s in row], suites)
        self.assertLessEqual(max(sum(weights[s] for s in row) for row in rows), 240)
        self.assertEqual(gate.partitions(suites, dict(a=float("nan"), b=-1, c="slow")), [suites])
        self.assertEqual(gate.partitions([], weights), [])

    def test_summary_rejects_missing_duplicate_failed_and_misattributed_work(self):
        suite = "res://tests/runner/self_suite.gd"
        identity = dict(commit="candidate", seed="1701", working_tree_dirty=False, passed=True,
                        engine="4.3.stable.official.77dcf97d8", engine_sha256="6e100966e49c69a2d4c163673f606eec1bafe54b4c6170eec5a6a2ee50756ddd",
                        machine="x86_64", source_snapshot={"sha256": "source"}, pin_manifest_sha256="verified")
        case = {"suite": suite, "case": "fixture", "category": "unit", "seed": "1701", "runs": [dict(assertions=1, failures=[], states=[])] * 2}
        result = dict(format=1, passed=True, complete=True, count=1, records=[case], errors=[])
        report = dict(identity, case_inventory={suite: ["fixture"]}, runs=[{"result": result}, {"result": result}],
                      helper_sources={name: "verified" for name in ("run_godot_tests.py", *gate.HELPERS)})
        plan = dict(commit="candidate", selection=dict(selected_count=1, inventory_count=1, suites=[suite]), parts=[[suite]])
        with (tempfile.TemporaryDirectory() as temp, mock.patch.object(gate, "git", return_value="candidate"),
              mock.patch.object(gate, "plan", return_value=plan) as planned, mock.patch.object(gate, "discover", return_value=[suite]),
              mock.patch.object(gate, "sha", return_value="verified"),
              mock.patch.object(gate, "expected_cases", return_value={suite: ["fixture"]}) as cases,
              mock.patch.object(gate, "inventory_sha256", return_value="source"), mock.patch.object(gate, "inventory", return_value={}),
              mock.patch.object(gate, "source_paths", return_value=[]), mock.patch.object(platform, "machine", return_value="x86_64")):
            directory = Path(temp)
            part = directory / (gate.ARTIFACT + "0") / "latest.json"
            part.parent.mkdir()
            part.write_text(json.dumps(report))
            gate.verify(plan, directory, "success", "event-base")
            cases.return_value = {suite: ["fixture", "stripped"]}
            with self.assertRaisesRegex(ValueError, "case listing disagrees"):
                gate.verify(plan, directory, "success", "event-base")
            cases.return_value = {suite: ["fixture"]}
            for field, value in (("passed", False), ("commit", "old"), ("case_inventory", {suite: ["fixture", "missing"]}),
                                 ("seed", "2"), ("engine_sha256", "f" * 64), ("source_snapshot", {"sha256": "other"}),
                                 ("helper_sources", {}), ("runs", report["runs"][:1])):
                with self.subTest(field=field):
                    part.write_text(json.dumps(dict(report, **{field: value})))
                    with self.assertRaises(ValueError):
                        gate.verify(plan, directory, "success", "event-base")
            part.write_text(json.dumps(report))
            for status in ("failure", "cancelled", "skipped"):
                with self.assertRaises(ValueError):
                    gate.verify(plan, directory, status, "event-base")
            duplicate = copy.deepcopy(plan)
            duplicate["parts"].append([suite])
            with self.assertRaises(ValueError):
                gate.verify(duplicate, directory, "success", "event-base")
            part.unlink()
            with self.assertRaises(ValueError):
                gate.verify(plan, directory, "success", "event-base")
            empty = dict(plan, selection=dict(selected_count=0, inventory_count=1, suites=[]), parts=[])
            with self.assertRaisesRegex(ValueError, "disagrees with event base"):
                gate.verify(empty, directory, "skipped", "event-base")
            planned.return_value = empty
            gate.verify(empty, directory, "skipped", "event-base")


if __name__ == "__main__":
    unittest.main()
