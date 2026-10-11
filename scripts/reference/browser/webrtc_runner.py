"""Bound each browser label by its actual room count and bootstrap allowance."""
from run import capture

def run_browser(command, environment, log, rooms):
    if type(rooms) is not int or rooms not in (1, 3):
        raise ValueError("browser room count must be one or three")
    returncode, output = capture(command, environment, log, timeout=rooms * 480 + 60)
    if returncode or 'SCRIPT ERROR:' in output or any(line.startswith('ERROR:') for line in output.splitlines()):
        raise RuntimeError(f'Browser witness failed: {command}; see {log}')
    return output
