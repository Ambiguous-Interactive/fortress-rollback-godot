#!/usr/bin/env python3
"""Read all PR feedback evidence; success proves coverage, never that feedback is addressed."""

import argparse
import json
import os
import re
import sys
import shutil
import subprocess
from email.message import Message
import urllib.parse

API = "https://api.github.com"


class FeedbackError(Exception):
    """Evidence is incomplete or no longer matches the requested PR head."""


_secrets = set()


def gh_command(arguments, environment):
    try:
        return subprocess.run(arguments, capture_output=True, text=True, encoding="utf-8", errors="strict",
                              timeout=30, env=environment, check=False)
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        raise FeedbackError("GitHub CLI could not complete the request; check installation and connectivity") from None


def reject_json_constant(value):
    raise ValueError("Non-JSON numeric constant")


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON object key")
        result[key] = value
    return result


def parse_response(result):
    if result.returncode != 0:
        raise FeedbackError("GitHub CLI API request failed; check authentication, repository access and connectivity")
    output = result.stdout.replace("\r\n", "\n")
    header_block, separator, body = output.partition("\n\n")
    lines = header_block.split("\n")
    match = re.fullmatch(r"HTTP/\d+(?:\.\d+)? ([0-9]{3})(?: [^\r\n]*)?", lines[0])
    if not separator or match is None:
        raise FeedbackError("Malformed GitHub CLI response headers")
    status = int(match.group(1))
    headers = Message()
    for line in lines[1:]:
        header = re.fullmatch(r"([!#$%&'*+.^_`|~0-9A-Za-z-]+):[ \t]*([^\r\n]*)", line)
        if header is None:
            raise FeedbackError("Malformed GitHub CLI response header")
        headers[header.group(1)] = header.group(2)
    # The private debug trace reveals redirects hidden by the final included response.
    trace_statuses = re.findall(r"(?m)^[<* \t]*HTTP/\d+(?:\.\d+)? ([0-9]{3})(?: [^\r\n]*)?$", result.stderr)
    trace_location = re.search(r"(?im)^[<* \t]*location[ \t]*:", result.stderr)
    if headers.get("Location") is not None or trace_location or any(300 <= int(code) < 400 for code in trace_statuses):
        raise FeedbackError("Redirected GitHub API evidence refused")
    if not 200 <= status < 300:
        raise FeedbackError(f"GitHub API HTTP {status}")
    if trace_statuses != [str(status)]:
        raise FeedbackError("Missing or ambiguous GitHub CLI response trace")
    links = headers.get_all("Link", [])
    if links:
        del headers["Link"]
        headers["Link"] = ", ".join(links)
    try:
        data = json.loads(body, object_pairs_hook=unique_json_object, parse_constant=reject_json_constant)
    except (ValueError, RecursionError):
        raise FeedbackError("GitHub CLI returned malformed JSON") from None
    return data, headers


def request_json(url):
    try:
        parsed = urllib.parse.urlsplit(url)
    except ValueError:
        raise FeedbackError("Unsafe GitHub API URL") from None
    if parsed.scheme != "https" or parsed.netloc != "api.github.com" or parsed.fragment or any(ord(char) < 32 for char in url):
        raise FeedbackError("Unsafe GitHub API URL")
    executable = shutil.which("gh")
    if executable is None:
        raise FeedbackError("GitHub CLI is unavailable; install gh and configure trusted authentication using .llm/skills/github-operations/SKILL.md")
    environment = os.environ.copy()
    for name in ("GH_DEBUG", "DEBUG", "GH_FORCE_TTY", "CLICOLOR_FORCE"):
        environment.pop(name, None)
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        if not environment.get(name):
            environment.pop(name, None)
    environment.update(GH_DEBUG="api", GH_PROMPT_DISABLED="1", GH_NO_UPDATE_NOTIFIER="1", NO_COLOR="1", GH_TELEMETRY="0")
    token = environment.get("GH_TOKEN") or environment.get("GITHUB_TOKEN")
    if not token:
        credentials = gh_command([executable, "auth", "token", "--hostname", "github.com"], environment)
        if credentials.returncode != 0 or not credentials.stdout.strip() or any(char.isspace() for char in credentials.stdout.strip()):
            raise FeedbackError("Authenticated GitHub CLI credential unavailable; configure a trusted credential using .llm/skills/github-operations/SKILL.md")
        token = credentials.stdout.strip()
    _secrets.add(token)
    arguments = [executable, "api", url, "--hostname", "github.com", "--method", "GET", "--include",
                 "--header", "Accept: application/vnd.github+json", "--header", "X-GitHub-Api-Version: 2022-11-28"]
    return parse_response(gh_command(arguments, environment))


def integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def get_object(url, requester):
    data, _ = requester(url)
    if not isinstance(data, dict):
        raise FeedbackError("Expected an API object")
    return data


def get_all(url, requester, key=None):
    values = []
    seen = set()
    item_ids = set()
    expected_count = None
    original = urllib.parse.urlsplit(url)
    while url:
        try:
            parsed = urllib.parse.urlsplit(url)
        except ValueError:
            raise FeedbackError("Unsafe pagination URL") from None
        if parsed.scheme != "https" or parsed.netloc != "api.github.com" or parsed.path != original.path or parsed.fragment:
            raise FeedbackError("Unsafe pagination URL")
        if url in seen:
            raise FeedbackError("Pagination cycle")
        seen.add(url)
        data, headers = requester(url)
        page = data.get(key) if key and isinstance(data, dict) else data if key is None else None
        if not isinstance(page, list) or any(not isinstance(item, dict) for item in page):
            raise FeedbackError("Expected an API list of objects")
        if key is not None:
            count = data.get("total_count")
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                raise FeedbackError("Missing or invalid API total_count")
            if expected_count is not None and count != expected_count:
                raise FeedbackError("API total_count changed during pagination; scan again")
            expected_count = count
        for item in page:
            identifier = item.get("id")
            if integer(identifier):
                if identifier in item_ids:
                    raise FeedbackError("Duplicate API record ID; pagination may have shifted, scan again")
                item_ids.add(identifier)
        values.extend(page)
        links = headers.get("Link", "")
        if not isinstance(links, str):
            raise FeedbackError("Malformed pagination header")
        url = None
        for link in links.split(","):
            if re.search(r';\s*rel\s*=\s*"?next\b', link):
                match = re.fullmatch(r'\s*<([^>]+)>\s*;\s*rel="?next"?\s*', link)
                if match is None or url is not None:
                    raise FeedbackError("Malformed next-page link")
                url = match.group(1)
    if expected_count is not None and len(values) != expected_count:
        raise FeedbackError("API total_count does not match pagination coverage")
    return values


def head_sha(pull):
    head = pull.get("head")
    sha = head.get("sha") if isinstance(head, dict) else None
    if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
        raise FeedbackError("Missing or invalid PR head SHA")
    return sha


def validate_comments(items, reviews=False):
    for item in items:
        user = item.get("user")
        if not integer(item.get("id")) or not isinstance(item.get("body"), str):
            raise FeedbackError("Invalid feedback ID or body")
        if not isinstance(user, dict) or not isinstance(user.get("login"), str) or not user["login"]:
            raise FeedbackError("Missing feedback author")
        if reviews and (not isinstance(item.get("state"), str) or item["state"] not in {"APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", "PENDING"}):
            raise FeedbackError("Invalid submitted review state")


def scan(repo, number, expected_head=None, requester=request_json):
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) is None or not integer(number):
        raise FeedbackError("Expected owner/repository and a positive PR number")
    if expected_head is not None and (not isinstance(expected_head, str) or re.fullmatch(r"[0-9a-f]{40}", expected_head) is None):
        raise FeedbackError("--expected-head must be a full 40-character hexadecimal SHA")
    base = f"{API}/repos/{repo}"
    pull_url = f"{base}/pulls/{number}"
    pull = get_object(pull_url, requester)
    sha = head_sha(pull)
    if expected_head is not None and sha != expected_head:
        raise FeedbackError("PR head does not match --expected-head")
    inline = get_all(f"{pull_url}/comments?per_page=100", requester)
    reviews = get_all(f"{pull_url}/reviews?per_page=100", requester)
    conversation = get_all(f"{base}/issues/{number}/comments?per_page=100", requester)
    validate_comments(inline)
    validate_comments(reviews, reviews=True)
    validate_comments(conversation)
    checks = get_all(f"{base}/commits/{sha}/check-runs?per_page=100&filter=all", requester, "check_runs")
    latest = {}
    for check in checks:
        output = check.get("output")
        suite = check.get("check_suite")
        app = check.get("app")
        if not integer(check.get("id")) or not isinstance(check.get("name"), str) or check.get("head_sha") != sha:
            raise FeedbackError("Invalid check run identity or head")
        if not isinstance(suite, dict) or not integer(suite.get("id")) or not isinstance(app, dict) or not integer(app.get("id")):
            raise FeedbackError("Invalid check suite or app")
        status = check.get("status")
        if not isinstance(status, str) or status not in {"queued", "in_progress", "completed", "waiting", "requested", "pending"} or "conclusion" not in check:
            raise FeedbackError("Invalid check status or missing conclusion")
        conclusion = check["conclusion"]
        conclusions = {"success", "failure", "neutral", "cancelled", "skipped", "timed_out", "action_required", "stale", "startup_failure"}
        if conclusion is not None and (not isinstance(conclusion, str) or conclusion not in conclusions):
            raise FeedbackError("Invalid check conclusion")
        if (check["status"] == "completed") != (conclusion is not None):
            raise FeedbackError("Check status and conclusion are inconsistent")
        if not isinstance(output, dict) or any(field not in output for field in ("title", "summary")):
            raise FeedbackError("Missing check output title or summary")
        if any(output.get(field) is not None and not isinstance(output[field], str) for field in ("title", "summary", "text")):
            raise FeedbackError("Invalid check output title, summary, or text")
        count = output.get("annotations_count") if isinstance(output, dict) else None
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise FeedbackError("Invalid annotation count")
        annotations = get_all(f"{base}/check-runs/{check['id']}/annotations?per_page=100", requester)
        if len(annotations) != count:
            raise FeedbackError("Annotation coverage changed or is incomplete; scan again")
        for annotation in annotations:
            if not isinstance(annotation.get("message"), str) or not isinstance(annotation.get("path"), str):
                raise FeedbackError("Invalid check annotation")
        check["feedback_annotations"] = annotations
        group = (suite["id"], app["id"], check["name"])
        latest[group] = max(latest.get(group, 0), check["id"])
    final_pull = get_object(pull_url, requester)
    if head_sha(final_pull) != sha:
        raise FeedbackError("PR head changed during scan; scan again")
    return {
        "repository": repo,
        "pull_request": number,
        "head_sha": sha,
        "coverage": {
            "rest_surfaces": "complete",
            "pagination": "complete",
            "head_rechecked": True,
            "thread_resolution": "unavailable in REST; inspect paginated GraphQL/MCP review threads separately",
            "feedback_adjudication": "not performed; read every body and annotation",
            "snapshot": "head stable; feedback can still arrive after this scan",
        },
        "pull_request_metadata": final_pull,
        "inline_comments": inline,
        "submitted_reviews": reviews,
        "conversation_comments": conversation,
        "check_runs_all_attempts": checks,
        "latest_check_run_ids_per_suite_app_name": sorted(latest.values()),
    }


def emit(value):
    rendered = json.dumps(value, indent=2, ensure_ascii=True)
    secrets = _secrets | {os.environ.get(name, "") for name in ("GH_TOKEN", "GITHUB_TOKEN")}
    for token in sorted(secrets - {""}, key=len, reverse=True):
        rendered = rendered.replace(token, "[REDACTED]")
        rendered = rendered.replace(json.dumps(token, ensure_ascii=True)[1:-1], "[REDACTED]")
    print(rendered)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("number", nargs="?", type=int)
    parser.add_argument("--pr", type=int)
    parser.add_argument("--repo", default="Ambiguous-Interactive/fortress-rollback-godot")
    parser.add_argument("--expected-head")
    arguments = parser.parse_args(argv)
    if (arguments.number is None) == (arguments.pr is None):
        parser.error("provide exactly one PR number, as a positional argument or --pr")
    number = arguments.pr if arguments.pr is not None else arguments.number
    try:
        emit(scan(arguments.repo, number, arguments.expected_head))
    except FeedbackError as error:
        emit({"coverage": "incomplete", "error": str(error)})
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
