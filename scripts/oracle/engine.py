#!/usr/bin/env python3
"""Resolve the Godot executable that an oracle launcher runs.

The default `make` targets pass the engine as a bare name, because the
`Makefile` sets `GODOT ?= godot`. Turning that name into a path with
`Path.resolve()` looks in the working directory only, so a pinned engine
installed on `PATH` was never found. The launchers failed with
`FileNotFoundError`, and they failed late: the Rust toolchain was
installed and the oracle was built before the engine was touched.

One rule is used by every launcher:

* a name that `PATH` holds resolves to that executable;
* any other name resolves as a path, relative to the working directory;
* the result must be an executable file.

The resolved path is used for the version probe, every execution, the
digest and the receipt, so a run started with `godot` and a run started
with `/usr/local/bin/godot` use the same bytes.
"""

import os
import shutil
from pathlib import Path


def resolve_engine(candidate):
    """Return the absolute path of the Godot executable to run.

    Raises `ValueError` with a readable message when the candidate names
    nothing that can run.
    """
    text = str(candidate)
    located = shutil.which(text)
    if located is not None:
        return Path(located).resolve()
    resolved = Path(text).expanduser().resolve()
    if not resolved.is_file():
        raise ValueError(f'godot executable not found: {text} (not on PATH and not a file)')
    if not os.access(resolved, os.X_OK):
        raise ValueError(f'godot executable is not executable: {resolved}')
    return resolved
