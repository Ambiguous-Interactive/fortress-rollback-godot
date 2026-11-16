#!/usr/bin/env python3
"""Run the committed wrap-flood corpus cases under the full differential gates.

The wave splits the P2P family so the committed ring-wrap schedules load
from fixtures instead of paying p2p_wrap.build()'s quadratic replays inside the
launcher that owns the rest of the corpus; every launch-time gate (twice per
side, raw compression validation, per-machine evidence and controls) still
runs against the current pinned binary here.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import p2p_launch

if __name__ == '__main__':
    p2p_launch.main(wrap_only=True)
