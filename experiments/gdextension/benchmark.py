"""Run each backend twice in fresh processes and compare ordered requests and game bytes."""
import argparse
import hashlib
import json
import math
import shutil
import statistics
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path

from export import CACHE, HERE, SCRATCH, prepared_editor


def run(command):
    proc = subprocess.run(command, capture_output=True, text=True, timeout=90)
    records = [line[6:] for line in proc.stdout.splitlines() if line.startswith("BENCH ")]
    if proc.returncode or len(records) != 1:
        raise RuntimeError((proc.stdout + proc.stderr)[-2000:])
    return json.loads(records[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", choices=["4.3", "4.7.2"])
    parser.add_argument("--editor", type=Path)
    parser.add_argument("--rust-peer-dir", type=Path, default=CACHE / "target/gdextension/reference/release")
    args = parser.parse_args()
    version = args.version
    scratch = SCRATCH
    editor = args.editor or prepared_editor(version)
    with tempfile.TemporaryDirectory(dir=scratch) as tmp:
        project = Path(tmp)
        (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Benchmark"\n')
        shutil.copy(HERE / "bench.gd", project)
        with zipfile.ZipFile(scratch / version / "linux/addon.zip") as archive:
            archive.extractall(project)
        (project / ".godot").mkdir()
        (project / ".godot/extension_list.cfg").write_text("res://addons/fortress_native/fortress.gdextension\n")
        base = [editor, "--headless", "--path", project]
        subprocess.run(base + ["--import"], check=True, stdout=subprocess.DEVNULL, timeout=90)
        subprocess.run(base + ["--script", "res://bench.gd", "--", "sync-control", "2"], check=True, capture_output=True, timeout=90)
        for players in [2, 8]:
            expected = struct.pack("<I", 256) + b"".join(struct.pack("<I", (i+1)*32896) for i in range(players))
            trace = None
            orders = (("rust", "native", "port"), ("port", "native", "rust"))
            samples = {backend: [] for backend in orders[0]}
            for order in orders:
                for backend in order:
                    command = ([args.rust_peer_dir / "sync-bench", str(players)] if backend == "rust" else
                               base + ["--script", "res://bench.gd", "--", backend, str(players)])
                    record = run(command)
                    if bytes.fromhex(record["state"]) != expected.ljust(4096, b"\x00"):
                        raise ValueError(f"{backend} final bytes differ")
                    if trace is None:
                        trace = record["trace"]
                    if trace != record["trace"] or not any(row.startswith("L") for row in trace):
                        raise ValueError(f"{backend} ordered requests differ")
                    if len(record["ticks"]) != 256 or sum(row.startswith("L") for row in trace) != 253:
                        raise ValueError("unexpected rollback workload")
                    samples[backend].append(record)
            for backend, records in samples.items():
                times = [tick for record in records for tick in record["ticks"]]
                # After the check distance of two, every step begins a rewind.
                rollback_times = [tick for record in records for tick in record["ticks"][3:]]
                copies = [copy for record in records for copy in record["copies"]]
                print(json.dumps(dict(version=version, players=players, backend=backend, ticks=len(times),
                                      orders=orders, timing_samples_us=[record["ticks"] for record in records],
                                      p50_us=statistics.median(times), p99_us=sorted(times)[math.ceil(.99*len(times))-1],
                                      max_us=max(times), worst_rollback_us=max(rollback_times), snapshot_copy_mean_us=statistics.mean(copies),
                                      request_sha256=hashlib.sha256("\n".join(trace).encode()).hexdigest())))


if __name__ == "__main__":
    main()
