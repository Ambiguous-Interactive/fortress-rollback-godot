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
    timeout = 360 if "--device" in options else 90
    receipts = []
    for slot, control in [(0, "none"), (1, "none"), (0, "restore"), (0, "encoding")]:
        command = [sys.executable, HERE / "qualify.py", *options, "--slot", str(slot), "--control", control]
        try:
            proc = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            diagnostic = (exc.stderr or b"").decode(errors="replace")
            raise RuntimeError(f"{control} control timed out for slot {slot}: {diagnostic[-8000:]}") from exc
        if control == "none":
            if proc.returncode:
                raise RuntimeError(proc.stderr[-8000:])
            receipt = json.loads(proc.stdout.splitlines()[-1])
        else:
            diagnostics = proc.stderr.splitlines()
            diagnostic = diagnostics[-1] if diagnostics else ""
            expected = "restored state differs at observed frame " if control == "restore" else "input encoding differs at frame 0"
            if proc.returncode != 1 or not diagnostic.startswith(expected):
                raise RuntimeError(f"{control} control: {proc.returncode}, {proc.stderr[-8000:]}")
            receipt = {"rejected": diagnostic}
        receipts.append({"slot": slot, "control": control, **receipt})
    print(json.dumps(receipts))


if __name__ == "__main__":
    main()
