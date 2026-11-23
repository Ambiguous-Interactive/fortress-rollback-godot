"""Bounded, private source images for native Godot test execution."""
from __future__ import annotations

from contextlib import ExitStack, contextmanager
import errno
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

MAX_FILES = 8192
MAX_BYTES = 64 * 1024 * 1024
GIT_TIMEOUT = 30
EXCLUDED = {".git", ".cache", ".godot", "progress", "__pycache__", "node_modules", "worktrees"}


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], cwd=root, encoding="utf-8", errors="strict", timeout=GIT_TIMEOUT)


def source_paths(root: Path) -> list[str]:
    paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0")
    return sorted({name for name in paths if name and not EXCLUDED.intersection(Path(name).parts)})


@contextmanager
def source_directory(root: Path, relative: Path):
    """Pin one sibling group below the source root without following an in-tree symlink."""
    with ExitStack() as opened:
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        opened.callback(os.close, directory)
        for part in relative.parts:
            try:
                directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            except FileNotFoundError:
                yield None  # Git still lists tracked deletions.
                return
            except NotADirectoryError:
                if stat.S_ISLNK(os.stat(part, dir_fd=directory, follow_symlinks=False).st_mode):
                    raise ValueError("source_symlink")
                raise
            opened.callback(os.close, directory)
        yield directory


def read_source(directory: int, leaf: str, remaining: int) -> tuple[bytes, int]:
    try:
        descriptor = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise ValueError("source_symlink") from error
        raise
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("source_not_regular")
        if metadata.st_size > remaining:
            raise ValueError("source_byte_limit")
        with open(descriptor, "rb", closefd=False) as stream:
            data = stream.read(metadata.st_size + 1)
        if len(data) != metadata.st_size:
            raise ValueError("source_changed_during_capture")
        return data, stat.S_IMODE(metadata.st_mode)
    finally:
        os.close(descriptor)


def inventory(root: Path, names: list[str], destination: Path | None = None) -> dict:
    if len(names) > MAX_FILES:
        raise ValueError("source_file_limit")
    directories = {}
    for name in names:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("unsafe_source_path")
        directories.setdefault(path.parent, []).append(path.name)

    files = {}
    total = 0
    for parent, leaves in directories.items():
        with source_directory(root, parent) as directory:
            if directory is None:
                continue
            if destination is not None:
                (destination / parent).mkdir(parents=True, exist_ok=True)
            for leaf in leaves:
                try:
                    data, mode = read_source(directory, leaf, MAX_BYTES - total)
                except FileNotFoundError:
                    continue
                total += len(data)
                name = (parent / leaf).as_posix()
                files[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "mode": mode}
                if destination is not None:
                    target = destination / name
                    target.write_bytes(data)
                    target.chmod(mode)
    return dict(sorted(files.items()))


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
            self.files = inventory(self.root, names, self.path)
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
        pending = [self.path]
        while pending:
            with os.scandir(pending.pop()) as entries:
                for entry in entries:
                    if entry.name in EXCLUDED:
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(entry.path)
                    else:
                        name = Path(entry.path).relative_to(self.path).as_posix()
                        if not entry.is_file(follow_symlinks=False) or name not in self.files:
                            raise ValueError("snapshot_changed")
                        names.append(name)
        if inventory(self.path, names) != self.files:
            raise ValueError("snapshot_changed")

    def evidence(self) -> dict:
        encoded = json.dumps(self.files, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return {"path": str(self.path), "files": self.files, "sha256": hashlib.sha256(encoded).hexdigest()}

    def __exit__(self, *_):
        self.temporary.cleanup()
