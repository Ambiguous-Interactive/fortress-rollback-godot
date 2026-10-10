"""Coverage and fail-closed checks for the read-only PR feedback backstop."""

import contextlib
import copy
import importlib.util
import io
import json
import os
import subprocess
import sys
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


# Value: protects=authenticated CLI coverage and redacted failures; fails_when=anonymous/malformed evidence accepted;
# why_new=existing fixtures bypass requester; seam=subprocess only
class GhRequesterTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.binary = patch.object(feedback.shutil, "which", return_value="/fake/gh")
        self.binary.start()
        self.process = patch.object(feedback.subprocess, "run")
        self.run = self.process.start()
        self.addCleanup(self.environment.stop)
        self.addCleanup(self.binary.stop)
        self.addCleanup(self.process.stop)
        feedback._secrets.clear()

    def response(self, body, headers=None, status=200, trace=None):
        lines = [f"HTTP/2.0 {status} OK", "Content-Type: application/json"]
        lines.extend(f"{key}: {value}" for key, value in (headers or {}).items())
        return subprocess.CompletedProcess([], 0, "\r\n".join(lines) + "\r\n\r\n" + json.dumps(body), trace or f"< HTTP/2.0 {status} OK\n")

    def configure_process(self, response):
        def execute(arguments, **options):
            self.assertTrue(options["capture_output"])
            self.assertTrue(options["text"])
            self.assertEqual(options["timeout"], 30)
            self.assertNotIn("stored-secret", str(arguments))
            if arguments[1:3] == ["auth", "token"]:
                return subprocess.CompletedProcess(arguments, 0, "stored-secret\n", "")
            self.assertEqual(arguments[1], "api")
            self.assertIn("--include", arguments)
            self.assertNotIn("--verbose", arguments)
            self.assertEqual(options["env"]["GH_DEBUG"], "api")
            self.assertEqual(arguments[arguments.index("--hostname")+1], "github.com")
            self.assertNotIn("--paginate", arguments)
            return response(arguments[2]) if callable(response) else response
        self.run.side_effect = execute

    def test_configured_auth_keeps_real_headers_and_paginated_coverage(self):
        fixture = Fixture()
        self.configure_process(lambda url: self.response(*fixture(url)))
        result = feedback.scan("wallstop/fortress-rollback-godot", 1)
        self.assertEqual(len(result["inline_comments"]), 2)
        self.assertEqual(len(result["check_runs_all_attempts"][0]["feedback_annotations"]), 2)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            feedback.emit({"body": "stored-secret"})
        self.assertNotIn("stored-secret", output.getvalue())
        self.assertIn("[REDACTED]", output.getvalue())

    def test_environment_token_does_not_require_configured_auth(self):
        self.configure_process(self.response([]))
        for name in ("GH_TOKEN", "GITHUB_TOKEN"):
            with self.subTest(name=name), patch.dict(os.environ, {name:"environment-secret"}):
                self.run.reset_mock()
                self.assertEqual(feedback.request_json(feedback.API+"/fixture")[0], [])
                self.assertEqual(self.run.call_count, 1)
                self.assertNotIn("environment-secret", str(self.run.call_args.args))

    def test_missing_binary_and_authentication_are_explicit(self):
        with patch.object(feedback.shutil, "which", return_value=None):
            with self.assertRaisesRegex(feedback.FeedbackError, "install.*gh"):
                feedback.request_json(feedback.API+"/fixture")
        results = (subprocess.CompletedProcess([],1,"private-secret","private-secret"),
                   subprocess.CompletedProcess([],0,"","private-secret"),
                   subprocess.CompletedProcess([],0,"malformed auth output","private-secret"))
        for result in results:
            self.run.return_value = result
            self.run.side_effect = None
            with self.subTest(result=result.returncode), self.assertRaisesRegex(feedback.FeedbackError, "trusted credential"):
                feedback.request_json(feedback.API+"/fixture")
            self.assertEqual(self.run.call_args.args[0][1:3], ["auth", "token"])

    def test_empty_environment_overrides_allow_stored_auth(self):
        self.configure_process(self.response([]))
        with patch.dict(os.environ, {"GH_TOKEN":"", "GITHUB_TOKEN":""}):
            feedback.request_json(feedback.API+"/fixture")
        self.assertEqual(self.run.call_count, 2)
        self.assertNotIn("GH_TOKEN", self.run.call_args.kwargs["env"])
        self.assertNotIn("GITHUB_TOKEN", self.run.call_args.kwargs["env"])

    def test_header_case_and_multiple_link_fields_preserve_pagination(self):
        response = self.response([])
        links = 'link: <https://api.github.com/fixture?page=1>; rel="first"\r\n'
        links += 'LINK: <https://api.github.com/fixture?page=2>; rel="next"'
        response.stdout = response.stdout.replace("Content-Type: application/json", links)
        self.configure_process(response)
        data, headers = feedback.request_json(feedback.API+"/fixture")
        self.assertEqual(data, [])
        self.assertIn('rel="first"', headers.get("Link"))
        self.assertIn('rel="next"', headers.get("Link"))

    def test_failed_commands_and_timeout_never_expose_cli_output(self):
        self.configure_process(subprocess.CompletedProcess([],1,"private-secret","private-secret"))
        with self.assertRaises(feedback.FeedbackError) as raised:
            feedback.request_json(feedback.API+"/fixture")
        self.assertNotIn("private-secret", str(raised.exception))
        for error in (OSError("private-secret"), subprocess.TimeoutExpired(["gh"],30,output="private-secret",stderr="private-secret")):
            self.run.side_effect = error
            with self.subTest(error=type(error).__name__), self.assertRaises(feedback.FeedbackError) as raised:
                feedback.request_json(feedback.API+"/fixture")
            self.assertNotIn("private-secret", str(raised.exception))

    def test_unsafe_urls_are_rejected_before_running_gh(self):
        urls = ("http://api.github.com/fixture", "https://evil.example/fixture", "https://api.github.com:443/fixture",
                "https://api.github.com/fixture#fragment", "https://user@api.github.com/fixture", "https://[invalid/fixture")
        for url in urls:
            with self.subTest(url=url), self.assertRaises(feedback.FeedbackError):
                feedback.request_json(url)
        self.run.assert_not_called()

    def test_malformed_ambiguous_and_redirected_evidence_fails(self):
        responses = [
            subprocess.CompletedProcess([],0,"{}",""),
            subprocess.CompletedProcess([],0,"HTTP/2.0 200 OK\nInvalid header\n\n{}","< HTTP/2.0 200 OK\n"),
            subprocess.CompletedProcess([],0,"HTTP/2.0 200 OK\n\nnot-json private-secret","< HTTP/2.0 200 OK\n"),
            subprocess.CompletedProcess([],0,"HTTP/2.0 200 OK\n\n{\"same\":1,\"same\":2}","< HTTP/2.0 200 OK\n"),
            subprocess.CompletedProcess([],0,"HTTP/2.0 200 OK\n\nNaN","< HTTP/2.0 200 OK\n"),
            self.response({}, {"Location":"https://evil.example/fixture"}),
            self.response({}, status=302),
            self.response({},trace="< HTTP/2.0 301 Moved\n< Location: https://evil.example/fixture\n< HTTP/2.0 200 OK\n"),
            self.response({},trace="no recognizable response markers"),
            self.response({},trace="< HTTP/2.0 200 OK\n< HTTP/2.0 200 OK\n"),
        ]
        for result in responses:
            with self.subTest(stdout=result.stdout[:50]):
                self.configure_process(result)
                with self.assertRaises(feedback.FeedbackError) as raised:
                    feedback.request_json(feedback.API+"/fixture")
                self.assertNotIn("private-secret",str(raised.exception))


class GhCommandEncodingTests(unittest.TestCase):
    # Value: preserves=Unicode API findings; fails_when=parent locale decodes UTF-8 incorrectly;
    # why_new=requester mocks do not exercise subprocess decoding; seam=none
    def test_real_subprocess_preserves_utf8_feedback_under_non_utf8_locale(self):
        body = {"body": "Café — 日本語", "user": {"login": "réviseur"}}
        payload = ("HTTP/2.0 200 OK\nContent-Type: application/json\n\n" + json.dumps(body, ensure_ascii=False)).encode("utf-8")
        diagnostic = "< HTTP/2.0 200 OK\nDiagnostic café 日本語\n".encode("utf-8")
        command = [sys.executable, "-c", f"import sys; sys.stdout.buffer.write({payload!r}); sys.stderr.buffer.write({diagnostic!r})"]
        # Patch the parent's default selector, covering Python UTF-8 mode too.
        # The child still emits literal UTF-8 bytes; subprocess.run itself is real.
        with patch.object(subprocess, "_text_encoding", return_value="latin-1"):
            control = subprocess.run(command, capture_output=True, text=True, check=True, env={})
            self.assertNotEqual(feedback.parse_response(control)[0], body, "control must reproduce locale mojibake")
            result = feedback.gh_command(command, {})
        self.assertEqual(feedback.parse_response(result)[0], body)
        self.assertEqual(result.stderr, diagnostic.decode("utf-8"))

    # Value: rejects=malformed UTF-8 without leaking CLI bytes; fails_when=decoding replaces or leaks;
    # why_new=real decode errors bypass existing mocked timeout/error checks; seam=none
    def test_real_subprocess_rejects_malformed_utf8_without_leaking_output(self):
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream):
                payload = b"private-cli-marker\xff"
                command = [sys.executable, "-c", f"import sys; sys.{stream}.buffer.write({payload!r})"]
                with patch.object(subprocess, "_text_encoding", return_value="latin-1"):
                    with self.assertRaises(feedback.FeedbackError) as raised:
                        feedback.gh_command(command, {})
                self.assertEqual(str(raised.exception),
                                 "GitHub CLI could not complete the request; check installation and connectivity")
                self.assertNotIn("private-cli-marker", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
