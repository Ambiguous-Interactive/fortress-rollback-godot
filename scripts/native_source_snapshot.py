"""Bounded, private source images for native Godot test execution."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import stat
import subprocess
import tempfile

MAX_FILES = 8192
MAX_BYTES = 64 * 1024 * 1024
EXCLUDED = {".git", ".cache", ".godot", "progress", "__pycache__", "node_modules", "worktrees"}


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], cwd=root, encoding="utf-8", errors="strict")


def source_paths(root: Path) -> list[str]:
    paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0")
    return sorted({name for name in paths if name and not EXCLUDED.intersection(Path(name).parts)})


def inventory(root: Path, names: list[str]) -> dict:
    files = {}
    total = 0
    if len(names) > MAX_FILES:
        raise ValueError("source_file_limit")
    for name in names:
        path = root / name
        if Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError("unsafe_source_path")
        if any(parent.is_symlink() for parent in [path, *path.parents] if parent != root.parent):
            raise ValueError("source_symlink")
        try:
            metadata = path.stat()
        except FileNotFoundError:
            continue  # A tracked deletion belongs to the working source image.
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("source_not_regular")
        total += metadata.st_size
        if total > MAX_BYTES:
            raise ValueError("source_byte_limit")
        with path.open("rb") as stream:
            data = stream.read(MAX_BYTES - (total - metadata.st_size) + 1)
        if len(data) != metadata.st_size:
            raise ValueError("source_changed_during_capture")
        files[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
                       "mode": stat.S_IMODE(metadata.st_mode)}
    return files


class SourceSnapshot:
    def __init__(self, root: Path):
        self.root = root
        self.temporary = None
        self.path = None
        self.files = {}
        self.commit = ""
        self.dirty = False

    def __enter__(self):
        scratch = self.root / ".cache/scratch"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="native-", dir=scratch)
        self.path = Path(self.temporary.name)
        try:
            self.commit = git(self.root, "rev-parse", "HEAD").strip()
            self.dirty = bool(git(self.root, "status", "--porcelain"))
            names = source_paths(self.root)
            self.files = inventory(self.root, names)
            for name, expected in self.files.items():
                with (self.root / name).open("rb") as stream:
                    data = stream.read(expected["bytes"] + 1)
                if len(data) != expected["bytes"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
                    raise ValueError("source_changed_during_capture")
                target = self.path / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(expected["mode"])
            if self.changed():
                raise ValueError("source_changed_during_capture")
            self.verify_image()
            return self
        except BaseException:
            self.temporary.cleanup()
            raise

    def changed(self) -> bool:
        return (git(self.root, "rev-parse", "HEAD").strip() != self.commit
                or inventory(self.root, source_paths(self.root)) != self.files)

    def verify_image(self) -> None:
        names = []
        for path in self.path.rglob("*"):
            if EXCLUDED.intersection(path.relative_to(self.path).parts):
                continue
            if path.is_symlink():
                raise ValueError("snapshot_changed")
            if path.is_file():
                names.append(path.relative_to(self.path).as_posix())
        names.sort()
        if inventory(self.path, names) != self.files:
            raise ValueError("snapshot_changed")

    def evidence(self) -> dict:
        encoded = json.dumps(self.files, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return {"path": str(self.path), "files": self.files, "sha256": hashlib.sha256(encoded).hexdigest()}

    def __exit__(self, *_):
        self.temporary.cleanup()
