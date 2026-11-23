"""Find all suites that can observe a change, widening to the inventory on uncertainty."""
from __future__ import annotations

from collections import defaultdict
import hashlib
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ("addons", "tests", "examples", "scripts")
SCANNED = (".gd", ".tscn", ".tres", ".json", ".cfg")
CLASS_NAME = re.compile(r"(?m)^(?:@\w+\s+)*class_name\s+(\w+)")
LITERAL = re.compile(r""""[^"\\\n]*(?:\\[^\n][^"\\\n]*)*"|'[^'\\\n]*(?:\\[^\n][^'\\\n]*)*'""")
ACCESS = re.compile(r"(?:(?<![\w])(?:pre)?load|\.(?:change_scene_to_file|change_dir|load_from_file)|ResourceLoader\.\w+"
                    r"|FileAccess\.(?!get_open_error\b)\w+|DirAccess\.(?:open|get_\w+_at|dir_exists_absolute))\s*\(\s*")
# These exact source versions have indirect reads of user files, supervisor output, SDK constants or selected suite paths.
# A new reader or an edit to one of these files restores the conservative fallback until its inputs are reviewed.
REVIEWED_READERS = {
    "examples/online/diagnostic_scene.gd": "7659c077fa390489ca7134ac5ec96146ca305362c4c657433976b1d408b0ff8f",
    "examples/online/lobby.gd": "bfd344360dd6b7de99dbcda9da250644dbe9be8b3f7c711572d007f194b59b45",
    "examples/online/replay_scene.gd": "c19e23dc7a92e4228538e21a1247c98a4e62ff957acdc6a4b8f7786733298866",
    "tests/oracle/p2p_trace.gd": "40fd08dd8fb4a34f08425e4006458d69120cc02890c1862d748c6da382182226",
    "tests/oracle/replay_session_trace.gd": "8cbabef01cca3cfa627555b73420a26884fe74451b0bb491f29b3c2854ad4955",
    "tests/runner/abort_supervisor.gd": "e22b3f8b74b9e31d61f0af1cb824be7f2a847f8252c913e0cd004373b0744113",
    "tests/runner/run_tests.gd": "2ee26d3f3f890bf0c30a4b05c0127971af0120a51f85181c76a91ac6152ae674",
    "tests/unit/test_diagnostic_viewer.gd": "e444e5f83a5ac1059fb711aafc44a41dc50680fe92b7adb555dc3389c8785679",
    "tests/unit/test_example_scene_exit.gd": "3f08ea607bfe91462171d1d1db2a9c0bef78428017a966b54f3d9522745c7e7e",
    "tests/unit/test_example_shortcuts.gd": "0c2396cc579298fd8a7b2d06770605a52b343ec45d0a8ad382a3efc2ba6c8ee6",
    "tests/unit/test_online_example.gd": "7f1f35e49bc9f65a6c0758848b71c3850ceeac6465cd3944fbb869d7e6972ccc",
    "tests/unit/test_replay_viewer.gd": "965cdc5e29f6263825cb8c6dcc850d81b568c9417012d534d88b24ef8545cad0",
    "tests/unit/test_replay_viewer_prefix.gd": "91522f8602503ac28d080fff29590d3e775fc4623eb3317116b23404c99db613",
}
# These host programs run in distinct entry points. Keep launcher imports, setup, workflow, pins and unknown files broad.
REFERENCE_TOOLS = {
    "native_online_probe.py", "online_install.py", "owned_process.py", "ownership_probes.py", "signalfish_webrtc_probe.py",
}


def independent_tool(path: str) -> bool:
    p = PurePosixPath(path)
    return (p.suffix == ".py" and path.startswith(("scripts/tests/", "scripts/oracle/", "scripts/llm/", "scripts/reference/browser/"))
            or p.suffix == ".rs" and path.startswith("scripts/oracle/rust/")
            or p.suffix == ".cjs" and path.startswith("scripts/reference/browser/")
            or p.parent.as_posix() == "scripts/reference" and (p.name in REFERENCE_TOOLS or p.name.startswith("test_") and p.suffix == ".py")
            or path == "scripts/package_addon.py")


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "--literal-pathspecs", *args], cwd=root, encoding="utf-8", errors="strict", timeout=30, stderr=subprocess.PIPE)


def changed_files(base: str, root: Path = ROOT) -> list[str]:
    """Keep both sides of renames and every local layer, including external untracked resources."""
    merge_base = git(root, "merge-base", "HEAD", base).strip()
    changes = set()
    for args in (("diff", merge_base, "HEAD"), ("diff", "--cached"), ("diff",)):
        changes.update(git(root, *args, "--name-only", "--no-renames", "-z", "--").split("\0"))
    changes.update(git(root, "ls-files", "--others", "--exclude-standard", "-z").split("\0"))
    return sorted(changes - {""})


def previous_class_names(base: str, changed: list[str], root: Path = ROOT) -> set[str]:
    sources = [name for name in changed if name.endswith(".gd")]
    if not sources:
        return set()
    names = set()
    blobs = set()
    for revision in {git(root, "merge-base", "HEAD", base).strip(), "HEAD"}:
        rows = git(root, "ls-tree", "-rz", revision, "--", *sources)
        blobs.update(row.split("\t", 1)[0].split()[2] for row in rows.split("\0") if row)
    rows = git(root, "ls-files", "--stage", "-z", "--", *sources)
    blobs.update(row.split("\t", 1)[0].split()[1] for row in rows.split("\0") if row)
    for oid in blobs:
        names.update(CLASS_NAME.findall(git(root, "cat-file", "blob", oid)))
    return names


def sources_in(root: Path):
    # Live callers pass Git's file inventory. Standalone fixture trees and private images contain only authored inputs.
    if (root / ".git").exists():
        return git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0")
    return (p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file())


def bound_argument(text: str, offset: int, constants: dict) -> bool:
    """Recognize an immutable literal or an immediately enclosing literal list loop."""
    symbol = re.match(r"(\w+)\s*[,)]", text[offset:])
    if not symbol:
        return False
    name = symbol[1]
    if constants.get(name, "").startswith(("res://", "user://")):
        return True
    previous = text[:offset].rsplit("\n", 2)
    if len(previous) < 3:
        return False
    loop = re.fullmatch(r"\s*for " + name + r": String in \[([A-Z_, 0-9]+)\]:", previous[1])
    if loop:
        return all(constants.get(key.strip(), "").startswith("res://") for key in loop[1].split(","))
    local = re.fullmatch(r'\s*var ' + name + r': String = "user://" \+ (\w+)', previous[1])
    return bool(local and re.fullmatch(r"[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+", constants.get(local[1], "")))


def inputs(path: str, text: str) -> tuple[set[str], bool]:
    used = set()
    opaque = False
    # Numeric fixtures contain many quoted fields but no resource spellings. A relative
    # resource needs a dot, a URI needs ://, and serialized scenes can escape both.
    if not path.endswith(".gd") and "." not in text and "://" not in text and "\\" not in text:
        return used, opaque
    for value in {match[0][1:-1] for match in LITERAL.finditer(text)}:
        if "\\" in value:
            # An escaped resource spelling is not a proven edge. Serialized resources can also encode the entire URI.
            if ("://" in value or PurePosixPath(value).suffix in SCANNED
                    or path == "project.godot" or path.endswith((".tscn", ".tres"))):
                opaque = True
                continue
        if path == "project.godot":
            value = value.removeprefix("*")  # Godot's global autoload notation.
        if value.startswith("res://"):
            target = value[6:]
            # A formatted string depends on everything under its last known directory.
            if "%" in target or "{" in target:
                prefix = re.split(r"[%{]", target, maxsplit=1)[0]
                target = prefix[:prefix.rfind("/") + 1]
            if target:
                used.add(posixpath.normpath(target) + ("/" if target.endswith("/") else ""))
            else:
                opaque = True
        elif value.startswith("uid://"):
            # Scenes usually also give a resource path, but a UID can resolve independently.
            opaque = True
        elif "." in value and "://" not in value and PurePosixPath(value).suffix in SCANNED:
            used.update((posixpath.normpath(value), posixpath.normpath(posixpath.join(posixpath.dirname(path), value))))
    if path.endswith(".gd"):
        opaque |= bool(re.search(r"\.source_code\s*=", text))
        constants = dict(re.findall(r'^const (\w+)(?:: String)? = "([^"\n]*)"\s*$', text, re.MULTILINE))
        for match in ACCESS.finditer(text):
            arg = LITERAL.match(text, match.end())
            if not arg:
                opaque |= not bound_argument(text, match.end(), constants)
                continue
            value = arg[0][1:-1]
            if "\\" in value:
                opaque = True
            elif not value.startswith(("res://", "user://")) and PurePosixPath(value).suffix not in SCANNED:
                opaque = True
            elif not text[arg.end():].lstrip().startswith((",", ")")):
                # A computed suffix can escape a literal directory through parent components.
                opaque = True
    if opaque and hashlib.sha256(text.encode()).hexdigest() == REVIEWED_READERS.get(path):
        opaque = False
        if path == "tests/runner/run_tests.gd":
            # _discover enumerates the selected category. discover() already includes each test in that directory.
            used.discard("tests/")
    return used, opaque


def selection(suites: list[str], changed: list[str], root: Path, old_names=frozenset(), paths=None) -> dict:
    def receipt(reason, selected, **details):
        return dict(reason=reason, changed_count=len(changed), inventory_count=len(suites), selected_count=len(selected), suites=list(selected), **details)

    relevant = {p.removesuffix(".uid") for p in changed}
    if not relevant:
        return receipt("no_changes", [])
    if any(p.startswith("tests/runner/") for p in relevant):
        return receipt("runner_changed", suites)
    available = set(paths if paths is not None else sources_in(root))
    texts = {p: (root / p).read_text(encoding="utf-8") for p in available
             if (p == "project.godot" or PurePosixPath(p).suffix in SCANNED) and (root / p).is_file()}
    classes = defaultdict(set)
    for p, text in texts.items():
        if p.endswith(".gd"):
            for name in CLASS_NAME.findall(text):
                classes[name].add(p)
    dependents = defaultdict(set)
    opaque_paths = set()
    reached = set(relevant)
    # Current and removed class prefixes let numeric fixtures skip identifier tokenization.
    old_names = set(old_names)
    prefixes = {name[:4] for name in classes.keys() | old_names}
    for p, text in texts.items():
        used, opaque = inputs(p, text)
        for target in used:
            # A binary scene/resource or an unsupported authored format can contain unobserved references.
            suffix = PurePosixPath(target).suffix
            if suffix and suffix not in SCANNED and (target in available or suffix in (".res", ".scn")):
                opaque = True
        if opaque:
            opaque_paths.add(p)
        words = set(re.findall(r"\w+", text)) if any(prefix in text for prefix in prefixes) else set()
        for name in words.intersection(classes):
            used.update(classes[name])
        if words.intersection(old_names):
            reached.add(p)
        for dep in used:
            dependents[dep.rstrip("/")].add(p)

    def targets(path: str):
        # A directory literal may omit its trailing slash, and an enumerated child may be new or deleted.
        yield path
        yield from (parent.as_posix() for parent in PurePosixPath(path).parents)

    def consumers(paths):
        seen = set(paths)
        pending = list(seen)
        while pending:
            p = pending.pop()
            for target in targets(p):
                for dep in dependents.get(target, ()):
                    if dep not in seen:
                        seen.add(dep)
                        pending.append(dep)
        return seen

    suite_paths = {s.removeprefix("res://") for s in suites}
    global_inputs = {"tests/runner/run_tests.gd", "project.godot"}
    for path in sorted(opaque_paths):
        if consumers([path]).intersection(suite_paths | global_inputs):
            return receipt("unresolved_resource", suites, path=path)
    for p in sorted(relevant):
        if p == "scripts/unit_suite_seconds.json":
            return receipt("partition_weights_changed", suites)
        if p.endswith(".md") or independent_tool(p):
            continue
        suffix = PurePosixPath(p).suffix
        if (p.split("/")[0] in SOURCES and suffix in (".gd", ".tscn", ".tres")
                or suffix in SCANNED and any(target in dependents for target in targets(p))):
            continue
        return receipt("unknown_input", suites, path=p)
    affected = consumers(reached)
    if global_inputs.intersection(affected):
        return receipt("runner_dependency", suites)
    selected = [s for s in suites if s.removeprefix("res://") in affected]
    if selected:
        return receipt("resource_dependency", selected)
    if all(p.endswith(".md") for p in relevant):
        return receipt("documentation_only", [])
    if all(independent_tool(p) or p.endswith(".md") for p in relevant):
        return receipt("verified_independent_tooling", [])
    return receipt("no_affected_suites", [])


def select(suites: list[str], changed: list[str], root: Path = ROOT, old_names=frozenset()) -> list[str]:
    return selection(suites, changed, root, old_names)["suites"]


def from_base(base: str, suites: list[str], root: Path, image: Path, paths) -> dict:
    try:
        changed = changed_files(base, root)
        old_names = previous_class_names(base, changed, root)
        result = selection(suites, changed, image, old_names, paths)
    except (OSError, UnicodeError, subprocess.SubprocessError):
        result = dict(reason="unresolved_diff_or_source", changed_count=None, inventory_count=len(suites), selected_count=len(suites), suites=list(suites))
    return dict(base=base, **result)
