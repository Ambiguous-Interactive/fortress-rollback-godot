"""Positive runs swap player slots. Each negative must fail at its intended observation."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("options", nargs=argparse.REMAINDER, help="arguments for qualify.py following --")
    options = parser.parse_args().options
    if options[:1] == ["--"]:
        options = options[1:]
    receipts = []
    for slot, control in [(0, "none"), (1, "none"), (0, "restore"), (0, "encoding")]:
        command = [sys.executable, HERE / "qualify.py", *options, "--slot", str(slot), "--control", control]
        proc = subprocess.run(command, text=True, capture_output=True, timeout=90)
        if control == "none":
            if proc.returncode:
                raise RuntimeError(proc.stderr[-2000:])
            receipt = json.loads(proc.stdout.splitlines()[-1])
        else:
            diagnostic = proc.stderr.splitlines()[-1]
            expected = "restored state differs at observed frame " if control == "restore" else "input encoding differs at frame 0"
            if proc.returncode != 1 or not diagnostic.startswith(expected):
                raise RuntimeError(f"{control} control: {proc.returncode}, {proc.stderr[-2000:]}")
            receipt = {"rejected": diagnostic}
        receipts.append({"slot": slot, "control": control, **receipt})
    print(json.dumps(receipts))


if __name__ == "__main__":
    main()
