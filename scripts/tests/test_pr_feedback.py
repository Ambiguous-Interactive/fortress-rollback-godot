"""Coverage and fail-closed checks for the read-only PR feedback backstop."""

import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "github" / "pr_feedback.py"
SPEC = importlib.util.spec_from_file_location("pr_feedback", SCRIPT)
feedback = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feedback)
SHA = "a" * 40
BASE = feedback.API + "/repos/wallstop/fortress-rollback-godot"
PULL = BASE + "/pulls/1"


def comment(identifier, body="Read this entire human finding"):
    return {"id": identifier, "body": body, "user": {"login": "human"}}


def check(identifier=8, suite=4):
    return {
        "id": identifier,
        "name": "Review",
        "head_sha": SHA,
        "check_suite": {"id": suite},
        "app": {"id": 3},
        "status": "completed",
        "conclusion": "success",
        "output": {"title": "Review result", "summary": None, "annotations_count": 2, "text": "Full check body"},
    }


class Fixture:
    def __init__(self):
        self.calls = []
        self.pull_reads = 0
        self.final_sha = SHA
        self.pages = {
            PULL + "/comments?per_page=100": ([comment(1)], {"Link": f'<{PULL}/comments?per_page=100&page=2>; rel="next"'}),
            PULL + "/comments?per_page=100&page=2": ([comment(2, "Later human finding")], {}),
            PULL + "/reviews?per_page=100": ([dict(comment(3, ""), state="CHANGES_REQUESTED")], {}),
            BASE + "/issues/1/comments?per_page=100": ([comment(4)], {}),
            BASE + f"/commits/{SHA}/check-runs?per_page=100&filter=all": ({"check_runs": [check()], "total_count": 1}, {}),
            BASE + "/check-runs/8/annotations?per_page=100": (
                [{"message": "First warning", "path": "file.gd"}],
                {"Link": f'<{BASE}/check-runs/8/annotations?per_page=100&page=2>; rel="next"'},
            ),
            BASE + "/check-runs/8/annotations?per_page=100&page=2": ([{"message": "Second warning", "path": "other.gd"}], {}),
        }

    def __call__(self, url):
        self.calls.append(url)
        if url == PULL:
            self.pull_reads += 1
            return {"head": {"sha": SHA if self.pull_reads == 1 else self.final_sha}}, {}
        return copy.deepcopy(self.pages[url])


class FeedbackTests(unittest.TestCase):
    def test_complete_report_keeps_all_bodies_and_annotations(self):
        fixture = Fixture()
        result = feedback.scan("wallstop/fortress-rollback-godot", 1, SHA, fixture)
        self.assertEqual([item["id"] for item in result["inline_comments"]], [1, 2])
        self.assertEqual(result["inline_comments"][1]["body"], "Later human finding")
        self.assertEqual(result["submitted_reviews"][0]["state"], "CHANGES_REQUESTED")
        self.assertEqual(len(result["check_runs_all_attempts"][0]["feedback_annotations"]), 2)
        self.assertEqual(result["check_runs_all_attempts"][0]["output"]["text"], "Full check body")
        self.assertEqual(fixture.pull_reads, 2)
        self.assertIn("not performed", result["coverage"]["feedback_adjudication"])
        self.assertIn("unavailable", result["coverage"]["thread_resolution"])

    def test_latest_attempts_are_scoped_by_suite_not_only_name(self):
        fixture = Fixture()
        url = BASE + f"/commits/{SHA}/check-runs?per_page=100&filter=all"
        fixture.pages[url] = ({"check_runs": [check(8), check(9), check(10, suite=5)], "total_count": 3}, {})
        for identifier in (9, 10):
            fixture.pages[BASE + f"/check-runs/{identifier}/annotations?per_page=100"] = (
                [{"message": "Warning", "path": "file.gd"}] * 2, {}
            )
        result = feedback.scan("wallstop/fortress-rollback-godot", 1, requester=fixture)
        self.assertEqual(result["latest_check_run_ids_per_suite_app_name"], [9, 10])
        self.assertEqual(len(result["check_runs_all_attempts"]), 3)

    def test_wrong_expected_head_stops_before_feedback(self):
        fixture = Fixture()
        with self.assertRaisesRegex(feedback.FeedbackError, "expected-head"):
            feedback.scan("wallstop/fortress-rollback-godot", 1, "b" * 40, fixture)
        self.assertEqual(fixture.calls, [PULL])

    def test_head_race_is_not_success(self):
        fixture = Fixture()
        fixture.final_sha = "b" * 40
        with self.assertRaisesRegex(feedback.FeedbackError, "head changed"):
            feedback.scan("wallstop/fortress-rollback-godot", 1, requester=fixture)

    def test_annotation_count_mismatch_is_not_complete(self):
        fixture = Fixture()
        fixture.pages[BASE + "/check-runs/8/annotations?per_page=100&page=2"] = ([], {})
        with self.assertRaisesRegex(feedback.FeedbackError, "Annotation coverage"):
            feedback.scan("wallstop/fortress-rollback-godot", 1, requester=fixture)

    def test_malformed_pages_and_feedback_fail_closed(self):
        for value in ({"message": "rate limit"}, [None], [dict(comment(1), body=None)], [dict(comment(1), user=None)]):
            with self.subTest(value=value):
                fixture = Fixture()
                fixture.pages[PULL + "/comments?per_page=100"] = (value, {})
                with self.assertRaises(feedback.FeedbackError):
                    feedback.scan("wallstop/fortress-rollback-godot", 1, requester=fixture)

    def test_unsafe_malformed_and_cyclic_pagination_fail(self):
        url = feedback.API + "/fixture"
        for link in (f'<{url}>; rel="next"', '<https://evil.example/fixture>; rel="next"', 'broken; rel="next"'):
            with self.subTest(link=link):
                with self.assertRaises(feedback.FeedbackError):
                    feedback.get_all(url, lambda _: ([], {"Link": link}))

    def test_check_runs_are_paginated(self):
        fixture = Fixture()
        url = BASE + f"/commits/{SHA}/check-runs?per_page=100&filter=all"
        fixture.pages[url] = ({"check_runs": [], "total_count": 1}, {"Link": f'<{url}&page=2>; rel="next"'})
        fixture.pages[url + "&page=2"] = ({"check_runs": [check()], "total_count": 1}, {})
        self.assertEqual(len(feedback.scan("wallstop/fortress-rollback-godot", 1, requester=fixture)["check_runs_all_attempts"]), 1)

    def test_truncated_or_missing_check_count_fails(self):
        for response in ({"check_runs": [check()], "total_count": 2}, {"check_runs": [check()]}):
            with self.subTest(response=response):
                fixture = Fixture()
                url = BASE + f"/commits/{SHA}/check-runs?per_page=100&filter=all"
                fixture.pages[url] = (response, {})
                with self.assertRaises(feedback.FeedbackError):
                    feedback.scan("wallstop/fortress-rollback-godot", 1, requester=fixture)

    def test_transport_and_invalid_json_errors_are_sanitized(self):
        for error in (feedback.urllib.error.HTTPError("secret", 403, "secret", {}, None), ValueError("secret")):
            with self.subTest(error=error):
                with patch.object(feedback.urllib.request, "build_opener") as opener:
                    opener.return_value.open.side_effect = error
                    with self.assertRaises(feedback.FeedbackError) as raised:
                        feedback.request_json(feedback.API + "/fixture")
                    self.assertNotIn("secret", str(raised.exception))

    def test_failure_exit_code_and_secret_redaction(self):
        output = io.StringIO()
        with patch.object(feedback, "scan", side_effect=feedback.FeedbackError("Incomplete evidence")):
            with contextlib.redirect_stdout(output):
                self.assertEqual(feedback.main(["1"]), 3)
        self.assertEqual(json.loads(output.getvalue())["coverage"], "incomplete")
        output = io.StringIO()
        with patch.dict(os.environ, {"GH_TOKEN": "private-secret"}):
            with contextlib.redirect_stdout(output):
                feedback.emit({"body": "private-secret"})
        self.assertNotIn("private-secret", output.getvalue())

    def test_named_pr_and_default_repository(self):
        with patch.object(feedback, "scan", return_value={}) as scanner:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(feedback.main(["--pr", "123", "--expected-head", SHA]), 0)
            scanner.assert_called_once_with("Ambiguous-Interactive/fortress-rollback-godot", 123, SHA)

    def test_invalid_supplied_expected_head_fails_before_api(self):
        for supplied in ("", "a" * 39, "g" * 40, "a" * 41, 123, False):
            with self.subTest(supplied=supplied):
                fixture = Fixture()
                with self.assertRaises(feedback.FeedbackError):
                    feedback.scan("wallstop/fortress-rollback-godot", 1, supplied, fixture)
                self.assertEqual(fixture.calls, [])

    def test_duplicate_ids_on_later_pages_fail_for_every_id_surface(self):
        paths = (
            (PULL + "/comments?per_page=100", [comment(1)], None),
            (PULL + "/reviews?per_page=100", [dict(comment(3), state="COMMENTED")], None),
            (BASE + "/issues/1/comments?per_page=100", [comment(4)], None),
            (BASE + f"/commits/{SHA}/check-runs?per_page=100&filter=all", [check()], "check_runs"),
        )
        for url, items, key in paths:
            with self.subTest(url=url):
                fixture = Fixture()
                response = {key: items, "total_count": 2} if key else items
                fixture.pages[url] = (response, {"Link": f'<{url}&page=2>; rel="next"'})
                fixture.pages[url + "&page=2"] = (response, {})
                with self.assertRaisesRegex(feedback.FeedbackError, "Duplicate"):
                    feedback.scan("wallstop/fortress-rollback-godot", 1, requester=fixture)

    def test_check_schema_mutations_fail_closed(self):
        mutations = (
            ("conclusion", {"state": "success"}),
            ("conclusion", "invented"),
            ("conclusion", None),
            ("status", "queued"),
            ("status", {"state": "completed"}),
            ("output", {"annotations_count": 2}),
            ("output", {"title": None, "summary": [], "annotations_count": 2}),
            ("output", {"title": False, "summary": None, "annotations_count": 2}),
            ("output", {"title": None, "summary": None, "text": {}, "annotations_count": 2}),
        )
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                fixture = Fixture()
                changed = check()
                changed[field] = value
                url = BASE + f"/commits/{SHA}/check-runs?per_page=100&filter=all"
                fixture.pages[url] = ({"check_runs": [changed], "total_count": 1}, {})
                with self.assertRaises(feedback.FeedbackError):
                    feedback.scan("wallstop/fortress-rollback-godot", 1, requester=fixture)

    def test_pending_null_conclusion_and_nullable_output_are_valid(self):
        fixture = Fixture()
        changed = check()
        changed.update(status="queued", conclusion=None, output={"title": None, "summary": None, "annotations_count": 2})
        url = BASE + f"/commits/{SHA}/check-runs?per_page=100&filter=all"
        fixture.pages[url] = ({"check_runs": [changed], "total_count": 1}, {})
        result = feedback.scan("wallstop/fortress-rollback-godot", 1, requester=fixture)
        self.assertIsNone(result["check_runs_all_attempts"][0]["conclusion"])


if __name__ == "__main__":
    unittest.main()
