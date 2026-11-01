"""Keep test-owned Git repositories independent of the caller's repository and configuration."""
from __future__ import annotations

import os


def fixture_environment() -> dict[str, str]:
    environment = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return environment
