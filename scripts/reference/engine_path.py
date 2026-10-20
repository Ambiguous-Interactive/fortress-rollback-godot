#!/usr/bin/env python3
"""Resolve the Godot executable that a probe or an oracle launcher runs.

The default `make` targets pass the engine as a bare name, because the
`Makefile` sets `GODOT ?= godot`. Turning that name into a working
directory path looks in the working directory only, so a pinned engine
installed on `PATH` was never found. The failure also came late: the Rust
toolchain was installed and the oracle was built before the engine was
touched.

One rule is used everywhere:

* a candidate that names a directory is a path, and is resolved against
  the working directory;
* any other candidate is looked up on `PATH` first, and resolved as a
  path when `PATH` does not hold it;
* the result must be an executable file.

The candidate is read as text, not as a `Path`. `Path('./godot')` is
`PosixPath('godot')`, so a path object cannot say that the caller named
the file in the working directory rather than a name on `PATH`.

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
    if os.sep not in text and (not os.altsep or os.altsep not in text):
        located = shutil.which(text)
        if located is not None:
            found = Path(located).resolve()
            if not found.is_file():
                raise ValueError(f'godot executable is not a file: {found}')
            return found
    resolved = Path(text).expanduser().resolve()
    if not resolved.is_file():
        raise ValueError(f'godot executable not found: {text} (not on PATH and not a file)')
    if not os.access(resolved, os.X_OK):
        raise ValueError(f'godot executable is not executable: {resolved}')
    return resolved
