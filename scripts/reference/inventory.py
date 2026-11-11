#!/usr/bin/env python3
"""Conservative source inventory; lexical discovery is never semantic coverage."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib

REPO = Path(__file__).resolve().parents[2]
DEFAULT_LEDGER = REPO / "docs/reference/parity-ledger.json"
ISSUE_BASE = "https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/"
STATES = {"pending", "covered", "deferred", "not-applicable", "intentional-divergence"}
RUN_MARKER = "FORTRESS_TEST_RESULT "
MARKERS = {
    "public_api_candidate": re.compile(r"^\s*pub(?:\([^)]*\))?\s+(?:async\s+|unsafe\s+|const\s+)*(?:fn|struct|enum|trait|type|const|static|use|mod)\b"),
    "test_attribute": re.compile(r"#\[(?:test|(?:\w+::)*test|kani::proof)\b"),
    "property_or_fuzz_candidate": re.compile(r"\b(?:proptest!|quickcheck!|fuzz_target!|loom::model|kani::any)"),
    "configuration_candidate": re.compile(r"#\[cfg(?:_attr)?\b|\b(?:impl\s+Default|fn\s+default|DEFAULT_[A-Z_]+)\b"),
    "doc_fence": re.compile(r"^\s*(?:///|//!|\*)?\s*```"),
    "allocation_candidate": re.compile(r"(?i)\b(?:allocations?|allocation.free|zero.alloc|GlobalAlloc|assert_no_alloc)\b"),
    "formal_obligation_candidate": re.compile(r"^(?:INVARIANTS?\b|PROPERTIES?\b|SPECIFICATION\b)|\b(?:assert!|kani::assert|solver\.assert)"),
    "rust_function_candidate": re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+|unsafe\s+|const\s+)*fn\s+\w+"),
}
TEXT_SUFFIXES = {".rs", ".md", ".toml", ".tla", ".cfg", ".smt2", ".txt", ".ndjson"}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def owner(path: str) -> tuple[str, int, str]:
    """Conservative initial routing, to be refined during the semantic audit."""
    name = path.lower().replace("_", "").replace("-", "")
    rules = [
        (("hotjoin", "reactivation"), "X6", 50, "Reserved-slot/reactivation safety"),
        (("spectatorfailover", "doublefailurerelay"), "X5", 49, "Spectator host failover safety"),
        (("coordinatedpeerdrop",), "X4", 48, "Confirmed-history protection during coordinated drops"),
        (("spectator",), "X3", 47, "Spectator session lifecycle and confirmed input delivery"),
        (("replay",), "X1", 45, "Deterministic recording, replay and malformed replay rejection"),
        (("inputdelay",), "X2", 46, "Exact input-delay transition frame semantics"),
        (("prediction",), "C2", 26, "Prediction, confirmation and first incorrect frame"),
        (("inputqueue",), "C1", 25, "Bounded queue ordering, capacity and delayed inputs"),
        (("sync\u002flayer", "synclayer", "savedstate", "rollback", "gamestatecell"), "C3", 27, "Complete snapshot restore and ordered rollback resimulation"),
        (("synctest",), "C4", 28, "Sync-test determinism and checksum validation"),
        (("wire", "codec", "serialization", "compression", "rle", "messages"), "P1", 30, "Bounded binary codec, wire compatibility and malformed packet handling"),
        (("handshake",), "P2", 31, "Handshake state transitions, duplicate handling and timeout boundaries"),
        (("timesync", "frameadvantage", "checksumexchange", "peer_drop", "peerdrop", "freezeconvergence"), "P4", 33, "Pacing, checksums, disconnects and confirmed history"),
        (("allocation", "alloc", "benches/"), "R3", 24, "Bounded allocations and measured native/browser costs"),
        (("rng", "hash", "checksum", "frameinfo"), "R1", 22, "Deterministic numeric, checksum and portable representation semantics"),
        (("sessions/", "src/lib.rs", "src/error.rs", "src/prelude.rs"), "C5", 29, "Expert session API, configuration, requests, events and lifecycle errors"),
        (("network/protocol", "network/buffer", "network/socketreceive"), "P3", 32, "Bounded input exchange, acknowledgements and retransmission"),
        (("network", "simulation"), "P5", 34, "Multi-peer network correctness under deterministic faults"),
        (("wasm", "emscripten", "godot"), "S5", 39, "Exported-browser integration and compatibility"),
        (("telemetry", "metrics"), "A3", 42, "Bounded diagnostics and observability"),
        (("examples/",), "A2", 41, "Reproducible client integration and examples"),
        (("specs/", "verification", "loom", "proofvec"), "V5", 20, "Reusable formal/property invariants and counterexample preservation"),
        (("proptestregressions", "fuzz/"), "V4", 19, "Regression corpus preservation and deterministic scenario shrinking"),
    ]
    for tokens, task, issue, behavior in rules:
        if any(token in name for token in tokens):
            return task, issue, behavior
    return "B2", 13, "Unknown: semantic behavior and applicability require source audit"


def families(path: str, text: str) -> list[str]:
    result = []
    if path.startswith("src/") and path.endswith(".rs"):
        result.append("library-source")
    prefixes = {"tests/": "integration-test-or-support", "fuzz/": "fuzz",
                "proptest-regressions/": "regression-corpus", "loom-tests/": "loom",
                "specs/": "formal-model-or-trace", "benches/": "benchmark", "examples/": "example"}
    result.extend(value for prefix, value in prefixes.items() if path.startswith(prefix))
    if path.endswith("Cargo.toml"):
        result.append("feature-and-build-configuration")
    for token, label in [("#[test]", "rust-tests"), ("kani::", "kani"), ("proptest", "property"),
                         ("z3::", "smt"), ("```", "documentation-code-candidate"),
                         ("golden", "wire-golden-or-reference-fixture")]:
        if token in text or token in path:
            result.append(label)
    if MARKERS["allocation_candidate"].search(text):
        result.append("allocation-contract-candidate")
    return sorted(set(result))


def scan(root: Path, pin: dict) -> dict:
    if not root.is_dir():
        raise ValueError(f"Missing extracted pinned source: {root}")
    files, records, features = {}, [], {}
    # No filename allowlist: newly introduced source languages and hidden assets
    # remain visible as drift, even before a classifier knows their semantics.
    for file in sorted(root.rglob("*")):
        if file.is_symlink():
            raise ValueError(f"Symlink not supported in source inventory: {file}")
        if not file.is_file():
            continue
        path = file.relative_to(root).as_posix()
        data = file.read_bytes()
        files[path] = digest(data)
        text = data.decode("utf-8") if file.suffix in TEXT_SUFFIXES else ""
        labels = families(path, text)
        if not labels:
            continue
        markers = []
        for line_number, line in enumerate(text.splitlines(), 1):
            for kind, pattern in MARKERS.items():
                if kind == "formal_obligation_candidate" and file.suffix not in {".tla", ".cfg", ".smt2"}:
                    continue
                if kind == "rust_function_candidate" and file.suffix != ".rs":
                    continue
                if pattern.search(line):
                    excerpt = line.strip()
                    markers.append([kind, line_number, excerpt])
        task, issue, behavior = owner(path)
        records.append({"id": f"fortress:{path}", "path": path,
                        "source_sha256": files[path], "source_revision": pin["revision"],
                        "families": labels, "markers": markers,
                        "protected_behavior": behavior,
                        "ownership": {"task": task, "issue": ISSUE_BASE + str(issue),
                                      "milestone_epic": ISSUE_BASE + str({"B": 3, "V": 4, "R": 5, "C": 6, "P": 7, "S": 8, "A": 9, "X": 10}[task[0]]),
                                      "review": "provisional-source-family-routing"}})
        if file.name == "Cargo.toml":
            features[path] = tomllib.loads(text).get("features", {})
    return {"source": {"repository": pin["repository"], "revision": pin["revision"],
                       "archive": pin["archive"]}, "files": files,
            "cargo_features": features, "records": records}


def decision() -> dict:
    return {"status": "pending", "applicability": "unknown",
            "rationale": "Source-family discovery only; semantic contracts and runtime-specific obligations remain unaudited.",
            "port_test_ids": [], "review": None}


def new_ledger(inventory: dict) -> dict:
    return {"schema_version": 1, "discovery": "lexical-source-family; not Rust AST or semantic coverage",
            "semantic_audit_complete": False, "inventory": inventory,
            "decisions": {record["id"]: decision() for record in inventory["records"]}}


IDENTITY_PATTERN = re.compile(r"^(?:res://(?P<suite>\S+?)(?:::(?P<case>\S+))?|(?P<script>\S+\.py)(?:::(?P<qualname>\S+))?)$")


def identity_error(identity) -> str | None:
    """Reject a mapped port test identity that names no executable port test.

    A mapping must name an existing repository suite (``res://tests/...gd`` with
    an optional ``::case``) or an existing repository Python script. Anything
    else is a forged identity and fails even without executed evidence.
    """
    if not isinstance(identity, str) or not (match := IDENTITY_PATTERN.match(identity)):
        return f"unparseable port test identity: {identity!r}"
    relative = match.group("suite") or match.group("script")
    if not (REPO / relative).is_file():
        return f"port test identity names a missing repository file: {identity}"
    return None


def identity_errors(ledger: dict) -> list[str]:
    errors = []
    for name, item in ledger.get("decisions", {}).items():
        if not isinstance(item, dict):
            continue
        for identity in item.get("port_test_ids") or []:
            if problem := identity_error(identity):
                errors.append(f"{name}: {problem}")
    return errors


def result_bundle_errors(bundle, origin: str, commit: str, pins_digest: str) -> list[str]:
    """Fail a bundle that did not pass complete work at this candidate commit."""
    errors = []
    if type(bundle) is not dict:
        return [f"{origin}: result bundle is not an object"]
    if bundle.get("format") != 1:
        errors.append(f"{origin}: bundle format differs")
    if bundle.get("passed") is not True:
        errors.append(f"{origin}: bundle did not pass")
    if bundle.get("working_tree_dirty") is not False:
        errors.append(f"{origin}: bundle ran on a dirty working tree")
    if bundle.get("commit") != commit:
        errors.append(f"{origin}: bundle commit differs from the candidate commit")
    if bundle.get("pin_manifest_sha256") != pins_digest:
        errors.append(f"{origin}: bundle pin manifest digest differs from this repository")
    for key in ("engine", "platform", "machine", "seed"):
        if type(bundle.get(key)) is not str or not bundle[key]:
            errors.append(f"{origin}: bundle platform evidence is absent: {key}")
    runs = bundle.get("runs")
    if type(runs) is not list or not runs:
        errors.append(f"{origin}: bundle records no executed run")
        return errors
    for run in runs:
        if type(run) is not dict or type(run.get("exit")) is not int or run["exit"] != 0:
            errors.append(f"{origin}: bundle contains a failed or unbounded run")
        command = run.get("command") if type(run) is dict else None
        if type(command) is not list or not command or any(type(part) is not str for part in command):
            errors.append(f"{origin}: bundle run command is absent or malformed")
    return errors


def executed_suite_cases(bundle, origin: str) -> tuple[dict, list[str]]:
    """Collect the complete passing suite/case identities one bundle recorded."""
    executed, errors = {}, []
    for run in bundle["runs"]:
        for line in (run.get("stdout") or "").splitlines():
            if not line.startswith(RUN_MARKER):
                continue
            try:
                report = json.loads(line[len(RUN_MARKER):])
            except ValueError:
                errors.append(f"{origin}: bundle test marker is unparsable")
                continue
            if (type(report) is not dict or report.get("format") != 1
                    or report.get("passed") is not True or report.get("complete") is not True):
                errors.append(f"{origin}: bundle test marker is failed or incomplete")
                continue
            records = report.get("records")
            if type(records) is not list:
                errors.append(f"{origin}: bundle test marker has no case records")
                continue
            for record in records:
                if type(record) is dict and type(record.get("suite")) is str and type(record.get("case")) is str:
                    executed[(record["suite"], record["case"])] = True
    return executed, errors


def binding_errors(ledger: dict, bundles: list, commit: str, pins_digest: str) -> list[str]:
    """Fail every mapping without executed passing evidence at this candidate commit.

    A result bundle is one launcher receipt file (``format: 1``) from
    ``scripts/run_godot_tests.py``: repository commit, working-tree state, engine,
    platform, machine, seed and pin-manifest digest, plus one ``runs`` entry per
    executed engine command whose ``stdout`` carries the runner's
    ``FORTRESS_TEST_RESULT`` markers. Another engineer reproduces it by running
    that launcher at the candidate commit on a clean tree and passing the
    resulting JSON file here with ``--results``.
    """
    errors = []
    for origin, bundle in enumerate(bundles):
        errors += result_bundle_errors(bundle, f"results[{origin}]", commit, pins_digest)
    satisfied: dict = {}
    for origin, bundle in enumerate(bundles):
        if type(bundle) is dict and type(bundle.get("runs")) is list:
            executed, marker_errors = executed_suite_cases(bundle, f"results[{origin}]")
            satisfied.update(executed)
            errors += marker_errors
    for name, item in ledger.get("decisions", {}).items():
        if not isinstance(item, dict):
            continue
        for test_id in item.get("port_test_ids") or []:
            if problem := identity_error(test_id):
                errors.append(f"{name}: {problem}")
                continue
            match = IDENTITY_PATTERN.match(test_id)
            if match.group("script"):
                errors.append(f"{name}: {test_id} needs its own receipt bundle; a runner bundle cannot bind it")
                continue
            suite, case = "res://" + match.group("suite"), match.group("case")
            if case is not None and (suite, case) not in satisfied:
                errors.append(f"{name}: {test_id} was not executed and passed in any provided bundle")
            elif case is None and not any(key[0] == suite for key in satisfied):
                errors.append(f"{name}: {test_id} was not executed and passed in any provided bundle")
    return errors


def validate(ledger: dict, inventory: dict, release: bool = False) -> list[str]:
    errors = identity_errors(ledger)
    if release:
        errors.append("Source-family schema is discovery evidence only; semantic coverage certification is not implemented")
    if ledger.get("schema_version") != 1:
        errors.append("Unsupported parity ledger schema")
    if ledger.get("inventory") != inventory:
        old = ledger.get("inventory", {}).get("files", {})
        current = inventory["files"]
        errors.append("Source inventory drift: " + json.dumps({
            "added": sorted(current.keys() - old.keys()), "removed": sorted(old.keys() - current.keys()),
            "changed": sorted(p for p in old.keys() & current.keys() if old[p] != current[p])}))
    expected = {record["id"] for record in inventory["records"]}
    decisions = ledger.get("decisions", {})
    if not isinstance(decisions, dict) or set(decisions) != expected:
        errors.append("Decision identities differ from discovered source families")
        return errors
    for identity, item in decisions.items():
        if not isinstance(item, dict) or item.get("status") not in STATES:
            errors.append(f"Invalid status: {identity}")
            continue
        if not isinstance(item.get("rationale"), str) or not item["rationale"].strip():
            errors.append(f"Missing applicability rationale: {identity}")
        if item.get("applicability") not in {"unknown", "supported", "excluded", "deferred", "divergent"}:
            errors.append(f"Invalid applicability: {identity}")
        tests = item.get("port_test_ids")
        if not isinstance(tests, list) or any(not isinstance(t, str) or not t.strip() for t in tests):
            errors.append(f"Invalid port test IDs: {identity}")
        if release:
            status = item["status"]
            review = item.get("review")
            if status == "pending" or item.get("applicability") == "unknown":
                errors.append(f"Unreviewed behavior blocks release: {identity}")
            if not isinstance(review, dict) or not all(review.get(k) for k in ("reviewer", "evidence", "revision")):
                errors.append(f"Missing reviewed applicability evidence: {identity}")
            if status == "covered" and (item.get("applicability") != "supported" or not tests):
                errors.append(f"Supported behavior lacks mapped port tests: {identity}")
            if status == "deferred" or (item.get("applicability") == "supported" and status != "covered"):
                errors.append(f"Uncovered supported or deferred behavior blocks release: {identity}")
    if release and ledger.get("semantic_audit_complete") is not True:
        errors.append("Incomplete semantic audit blocks release; lexical discovery cannot prove behavior coverage")
    return errors


def encode_ledger(ledger: dict) -> str:
    """Keep generated marker tuples on one line to reduce review/checkout noise."""
    encoded = json.dumps(ledger, indent=2, sort_keys=True)
    pattern = r'\[\n\s*("[^"\n]+"),\n\s*(\d+),\n\s*("(?:[^"\\]|\\.)*")\n\s*\]'
    return re.sub(pattern, lambda m: "[" + ", ".join(m.groups()) + "]", encoded) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--pins", type=Path, default=REPO / "docs/reference/pins.json")
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--write", action="store_true", help="Create initial ledger only; refuses overwrite")
    parser.add_argument("--release", action="store_true", help="Require semantic audit and reviewed coverage")
    parser.add_argument("--results", type=Path, action="append",
                        help="Launcher result bundle (format 1) binding mapped port tests to executed passing evidence")
    args = parser.parse_args()
    try:
        pin = json.loads(args.pins.read_text())["sources"]["fortress"]
        root = args.root or REPO / ".cache/reference" / pin["root"]
        inventory = scan(root, pin)
        if args.write:
            if args.release:
                raise ValueError("--write and --release cannot be combined")
            with args.ledger.open("x", encoding="utf-8") as out:
                out.write(encode_ledger(new_ledger(inventory)))
        else:
            ledger = json.loads(args.ledger.read_text())
            errors = validate(ledger, inventory, args.release)
            if args.results:
                commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, encoding="utf-8").strip()
                pins_digest = hashlib.sha256(args.pins.read_bytes()).hexdigest()
                bundles = []
                for path in args.results:
                    try:
                        bundles.append(json.loads(path.read_text(encoding="utf-8")))
                    except (OSError, ValueError) as error:
                        errors.append(f"results[{path}]: unreadable result bundle: {error}")
                errors += binding_errors(ledger, bundles, commit, pins_digest)
            if errors:
                for error in errors[:20]:
                    print(error, file=sys.stderr)
                if len(errors) > 20:
                    print(f"{len(errors) - 20} additional coverage failures omitted", file=sys.stderr)
                return 1
        print(f"Inventory verified: {len(inventory['files'])} files; {len(inventory['records'])} source families; revision {pin['revision']}")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Inventory failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
