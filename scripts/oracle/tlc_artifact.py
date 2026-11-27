"""Verify the TLC artifact from the launcher’s selected manifest."""

import shutil
from pathlib import Path
from tempfile import TemporaryDirectory

from launch import digest


ARTIFACT = 'tla2tools-1.8.0.jar'


def ensure_jar(path, source, expected_digest):
    if not source.is_file() or digest(source) != expected_digest:
        raise ValueError('repository TLC artifact missing or hash mismatch')
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(dir=path.parent) as directory:
            temporary = Path(directory) / path.name
            shutil.copyfile(source, temporary)
            if digest(temporary) != expected_digest:
                raise ValueError('copied TLC artifact hash mismatch')
            temporary.replace(path)
    if digest(path) != expected_digest:
        raise ValueError('cached TLC artifact hash mismatch')
