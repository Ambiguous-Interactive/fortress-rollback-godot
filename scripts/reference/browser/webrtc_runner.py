"""Bound a three-room browser label separately from single editor operations."""
from run import capture

LABEL_SECONDS = 3 * 480 + 60

def run_browser(command, environment, log):
    returncode, output = capture(command, environment, log, timeout=LABEL_SECONDS)
    if returncode or 'SCRIPT ERROR:' in output or any(line.startswith('ERROR:') for line in output.splitlines()):
        raise RuntimeError(f'Browser witness failed: {command}; see {log}')
    return output
