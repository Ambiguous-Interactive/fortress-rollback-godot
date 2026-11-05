"""Run the experimental spectator timeline with an explicitly shared development cache."""
import os
import sys
from pathlib import Path

worktree = Path(__file__).resolve().parents[3]
cache = Path(os.environ['FORTRESS_FETCH_PROBE_CACHE']).resolve()
sys.path.insert(0, str(worktree / 'scripts/reference'))
import signalfish_spectator_live
import fetch

for module in list(sys.modules.values()):
    if isinstance(getattr(module, 'CACHE', None), Path):
        module.CACHE = cache
fetch.fetch.__defaults__ = (False, cache)
signalfish_spectator_live.main()
