"""Exercise one exported Godot peer against a stock Fortress UDP peer on loopback."""
import argparse
import functools
import http.server
import json
import plistlib
import queue
import threading
import socket
import statistics
import struct
import subprocess
import time
from contextlib import ExitStack
from pathlib import Path

import mobile


def validate(report, state):
    frame, left, right = state
    history = report["history"]
    if len(history) != frame:
        raise ValueError(f"history length at frame {frame}")
    if [left, right] != [sum(row[i] for row in history) & 0xffffffff for i in range(2)]:
        raise ValueError(f"restored state differs at observed frame {frame}")
    # A newly delivered actual can be confirmed before the next correction.
    if frame >= 48 and report["confirmed"] >= 39:
        for n, row in enumerate(history[:40]):
            if row != [(n + 1) * 17, (n + 1) * 18]:
                raise ValueError(f"input encoding differs at frame {n}")


def read_peer(pipe, output):
    for line in pipe:
        output.put(line)


def peer_line(output):
    try:
        return output.get(timeout=5)
    except queue.Empty as error:
        raise TimeoutError("reference peer did not answer") from error


def stop(child):
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--peer", type=Path, required=True)
    parser.add_argument("--browser", type=Path)
    parser.add_argument("--engine", choices=["chromium", "firefox", "webkit"], default="chromium")
    parser.add_argument("--device", choices=["android", "ios"])
    parser.add_argument("--stall", action="store_true", help="hold packets until the prediction window stalls")
    parser.add_argument("--slot", type=int, choices=(0, 1), default=0)
    parser.add_argument("--control", choices=("none", "restore", "encoding"), default="none")
    args = parser.parse_args()
    ticks = 0
    last_frame = -1
    times = []
    held = []
    result = {}
    with ExitStack() as stack:
        udp = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
        udp.bind(("127.0.0.1", 0))
        udp.setblocking(False)
        peer = subprocess.Popen([args.peer, str(1 - args.slot), f"127.0.0.1:{udp.getsockname()[1]}"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        stack.callback(stop, peer)
        output = queue.Queue()
        threading.Thread(target=read_peer, args=(peer.stdout, output), daemon=True).start()
        addr = ("127.0.0.1", int(peer_line(output)))

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                try:
                    payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    response = self.tick(payload)
                except Exception as error:
                    result["error"] = str(error)
                    response = {"done": True}
                data = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def tick(self, gd):
                nonlocal ticks, last_frame
                if gd.get("ack"):
                    if not result.get("verified"):
                        raise ValueError("premature client completion")
                    result["done"] = True
                    return {"done": True}
                ticks += 1
                for packet in gd.get("packets", []):
                    udp.sendto(bytes.fromhex(packet), addr)
                peer.stdin.write("\n")
                peer.stdin.flush()
                rust = json.loads(peer_line(output))
                packets = []
                while True:
                    try:
                        packet, source = udp.recvfrom(65535)
                    except BlockingIOError:
                        break
                    if source != addr:
                        raise ValueError("unexpected UDP sender")
                    packets.append(packet.hex())
                frame = gd.get("frame", 0)
                if args.stall and frame >= 12 and frame == last_frame and "held_packets" not in result:
                    if gd["status"] != 1:
                        raise ValueError("binding reported an advance at the prediction limit")
                    result["prediction_stalled"] = True
                last_frame = frame
                delay = args.stall and not result.get("prediction_stalled")
                if 8 <= frame and (frame < 12 or delay):
                    held.extend(packets)
                    packets.clear()
                elif held:
                    # Drop one datagram and deliver the remaining late burst in reverse order.
                    if len(set(held[1:])) < 2 or held[1:] == list(reversed(held[1:])):
                        raise ValueError("held batch lacks a distinguishable reordered pair")
                    packets.extend(reversed(held[1:]))
                    result["held_packets"] = len(held)
                    held.clear()
                if gd:
                    if gd["status"] < 0:
                        raise ValueError("binding step failed")
                    validate(gd, struct.unpack("<III", bytes.fromhex(gd["state"])))
                    validate(rust, rust["state"])
                    if gd["status"] == 0:
                        times.append(gd["step_us"])
                    if min(frame, rust["state"][0]) >= 48 and min(gd["confirmed"], rust["confirmed"]) >= 39:
                        if min(gd["loads"], rust["loads"]) <= 0 or result.get("held_packets", 0) < 2:
                            raise ValueError("missing rollback or fault exposure")
                        if args.stall and not result.get("prediction_stalled"):
                            raise ValueError("prediction limit was not exercised")
                        if not gd["corrected_fault"]:
                            raise ValueError("late delivery never corrected a replayed row")
                        expected = struct.pack("<III", 40, 820 * 17, 820 * 18)
                        if bytes.fromhex(gd["checkpoint"]) != expected or struct.pack("<III", *rust["checkpoint"]) != expected:
                            raise ValueError("frame 40 checkpoint differs")
                        result.update(checkpoint=expected.hex(), verified=True, confirmed_rows=40, loads=[gd["loads"], rust["loads"]],
                                      p50_us=statistics.median(times), p99_us=sorted(times)[int(len(times)*.99)],
                                      max_us=max(times))
                        return {"finish": True}
                return {"slot": args.slot, "control": args.control, "packets": packets}

        handler = functools.partial(Handler, directory=args.export.parent)
        server = stack.enter_context(http.server.ThreadingHTTPServer(("127.0.0.1", mobile.PORT if args.device else 0), handler))
        base = f"http://127.0.0.1:{server.server_port}"
        child = None
        if args.device:
            mobile.launch(stack, args.device, args.export)
        else:
            executable = args.export.resolve()
            if executable.suffix == ".app":
                info = plistlib.loads((executable / "Contents/Info.plist").read_bytes())
                executable = executable / "Contents/MacOS" / info["CFBundleExecutable"]
            command = (["node", Path(__file__).with_name("browser.cjs"), args.engine, args.browser, f"{base}/{args.export.name}"]
                       if args.browser else [executable, "--headless", "--", f"{base}/tick"])
            child = subprocess.Popen(command)
            stack.callback(stop, child)
        server.timeout = .2
        deadline = time.monotonic() + 60
        while not result.get("done") and "error" not in result and (child is None or child.poll() is None) and time.monotonic() < deadline:
            server.handle_request()
        if "error" in result or not result.get("done"):
            raise SystemExit(result.get("error", f"no completion after {ticks} ticks"))
        if child is not None and not args.browser and child.wait(timeout=10) != 0:
            raise SystemExit("exported game exited unsuccessfully")
        print(json.dumps(result))


if __name__ == "__main__":
    main()
