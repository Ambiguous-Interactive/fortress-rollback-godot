"""Model-check the pinned upstream SpectatorSession TLA+ spec and a behavior mutant.

The spectator API in the Godot port plays confirmed host rows through the shared
driver (see docs/spectators.md). Its delay, catch-up, synchronization and
buffer-bound behavior is specified upstream by `specs/tla/SpectatorSession.tla`.
This module runs the reviewed TLC jar on that pinned spec to confirm its safety
invariants hold, then runs a deliberately unsafe behavior mutant and requires
TLC to reject it. It is the model-side half of issue #131 acceptance #5.

The spec and its configuration are read from the verified upstream tree; this
module never edits them. The mutant is written to a scratch copy.
"""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/reference'))

from fetch import CACHE, digest, load_manifest  # noqa: E402

REVISION = 'f13cd5c0f2815926785a395947e18da0dbea0dd8'
UPSTREAM = CACHE / ('fortress-rollback-' + REVISION)
SPEC = Path('specs/tla/SpectatorSession.tla')
CONFIG = Path('specs/tla/SpectatorSession.cfg')
JAR_PIN = load_manifest()['artifacts']['tla2tools-1.8.0.jar']
JAR_SOURCE = ROOT / JAR_PIN['repository_path']
JAR_SHA256 = JAR_PIN['digest']

REQUIRED_INVARIANTS = ['TypeInvariant', 'SpectatorFrameBounded', 'BufferAccessValid', 'FramesBehindNonNegative', 'SafetyInvariant']

# Remove the "have inputs to consume" guard and the per-frame input-availability
# conjunct from the normal advance. A spectator can then advance past the last
# received frame, which must break SpectatorFrameBounded.
MUTANT_BEFORE = """AdvanceFrameNormal ==
    /\\ sessionState = "Running"
    /\\ ~inCatchupMode
    /\\ currentFrame # NULL_FRAME
    /\\ currentFrame < MAX_FRAME
    /\\ currentFrame < lastRecvFrame  \\* Have inputs to consume
    /\\ LET nextFrame == currentFrame + 1
           idx == BufferIndexFor(nextFrame)
       IN
        /\\ inputFrames[idx] = nextFrame  \\* Inputs available for next frame
        /\\ currentFrame' = nextFrame"""
MUTANT_AFTER = """AdvanceFrameNormal ==
    /\\ sessionState = "Running"
    /\\ ~inCatchupMode
    /\\ currentFrame # NULL_FRAME
    /\\ currentFrame < MAX_FRAME
    /\\ LET nextFrame == currentFrame + 1
           idx == BufferIndexFor(nextFrame)
       IN
        /\\ currentFrame' = nextFrame"""


def _java():
    probe = subprocess.run(['java', '-version'], capture_output=True, text=True, encoding='utf-8', timeout=20)
    if probe.returncode:
        raise ValueError('Java version probe failed')
    return (probe.stdout + probe.stderr).strip()


def validate_config(config_text):
    """Refuse a pinned configuration that dropped a required safety invariant."""
    missing = [invariant for invariant in REQUIRED_INVARIANTS if f'INVARIANT {invariant}' not in config_text]
    if missing:
        raise ValueError('pinned configuration dropped required invariants: ' + ', '.join(missing))


def mutate(source):
    """Return the deliberately unsafe spectator model, refusing an unmoved anchor."""
    if source.count(MUTANT_BEFORE) != 1:
        raise ValueError('pinned advance action no longer matches the reviewed mutant anchor')
    return source.replace(MUTANT_BEFORE, MUTANT_AFTER)


def _read_outcome(returncode, log, label, expect_ok):
    if expect_ok:
        if returncode != 0 or 'No error has been found' not in log:
            raise ValueError(f'{label}: pinned SpectatorSession model did not verify')
        return {'returncode': returncode, 'verified': True}
    if 'is violated' not in log:
        raise ValueError(f'{label}: unsafe mutant survived model checking')
    if returncode == 0:
        raise ValueError(f'{label}: TLC reported a violation but exited zero')
    return {'returncode': returncode, 'rejected': True,
            'violation': next(line.strip() for line in log.splitlines() if 'is violated' in line)}


def ensure_jar(path):
    """Verify the reviewed fixture in-repo, then seed the cache from it."""
    if not JAR_SOURCE.is_file() or digest(JAR_SOURCE) != JAR_SHA256:
        raise ValueError('repository TLC artifact missing or hash mismatch')
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix('.download')
        try:
            temporary.write_bytes(JAR_SOURCE.read_bytes())
            if digest(temporary) != JAR_SHA256:
                raise ValueError('copied TLC artifact hash mismatch')
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    if digest(path) != JAR_SHA256:
        raise ValueError('cached TLC artifact hash mismatch')


def _run(jar, spec, config, output, label, expect_ok):
    command = ['java', '-XX:+UseParallelGC', '-jar', str(jar), '-config', str(config),
               '-workers', 'auto', '-deadlock', '-metadir', str((output / (label + '-states')).resolve()), str(spec)]
    result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', timeout=300)
    log = result.stdout + result.stderr
    (output / f'{label}.log').write_text(log)
    return _read_outcome(result.returncode, log, label, expect_ok)


def check(output, jar):
    """Verify the pinned spec, then require the unsafe mutant to be rejected."""
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    spec = UPSTREAM / SPEC
    config = UPSTREAM / CONFIG
    if not spec.is_file() or not config.is_file():
        raise ValueError('pinned SpectatorSession model missing from verified tree')
    configure = config.read_text()
    validate_config(configure)
    positive = _run(jar, spec, config, output, 'pinned', expect_ok=True)
    mutant_dir = output / 'mutant'
    mutant_dir.mkdir(parents=True, exist_ok=True)
    mutated = mutant_dir / SPEC.name
    mutated.write_text(mutate(spec.read_text()))
    mutant_config = mutant_dir / CONFIG.name
    mutant_config.write_text(configure)
    negative = _run(jar, mutated, mutant_config, output, 'mutant', expect_ok=False)
    return {'complete': True, 'java_version': _java(), 'spec': str(SPEC), 'config': str(CONFIG),
            'spec_sha256': digest(spec), 'config_sha256': digest(config), 'TLC_sha256': digest(jar),
            'required_invariants': REQUIRED_INVARIANTS, 'pinned': positive, 'mutant': negative,
            'mutant_sha256': digest(mutated)}
