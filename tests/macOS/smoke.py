"""Exercise the bundled runtime and the exact JSON interface used by SwiftUI."""
import json
import os
from pathlib import Path
import select
import subprocess
import time
import uuid

RUNTIME = Path(os.environ.get("OPENSOUND_ROOT", Path(__file__).resolve().parents[2].parent / "OpenSound")) / "builds/macOS/Parvi.app/Contents/Resources/runtime"


class Instance:
    def __init__(self, index, desk=""):
        erts = next(RUNTIME.glob("erts-*"))
        self.node = f"parvi_mac_{os.getpid() * 10 + index}@127.0.0.1"
        self.cookie = uuid.uuid4().hex
        env = dict(os.environ, ROOTDIR=str(RUNTIME), BINDIR=str(erts / "bin"),
                   EMU="beam", PROGNAME="erl", ERL_EPMD_ADDRESS="127.0.0.1", PARVI_RECEPTION_DESK_URL="")
        if desk is None:
            env.pop("PARVI_RECEPTION_DESK_URL", None)  # Exercise the bundled default.
        else:
            env["PARVI_RECEPTION_DESK_URL"] = desk
        self.process = subprocess.Popen([
            str(erts / "bin/erlexec"), "-boot",
            str(RUNTIME / "releases/0.1.0/start"), "-noshell", "-name", self.node,
            "-setcookie", self.cookie, "-kernel", "inet_dist_use_interface", "{127,0,0,1}",
            "-s", "parvi_bridge", "main"], env=env, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, bufsize=0)
        self.buffer = b""

    def request(self, method, **args):
        self.process.stdin.write((json.dumps(dict(method=method, **args)) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                if not select.select([self.process.stdout], [], [], 1)[0]:
                    continue
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError(f"Erlang exited: {self.process.poll()}")
                self.buffer += chunk
                if b"\n" not in self.buffer:
                    continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                print("Runtime:", line.decode(errors="replace").rstrip())
                continue  # startup logs, if any, precede bridge configuration
        raise TimeoutError("No bridge response within 10 seconds")

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def await_state(instance, predicate):
    for _ in range(100):
        state = instance.request("snapshot")
        if predicate(state):
            return state
        time.sleep(0.05)
    raise AssertionError("State did not converge")


def main():
    first = Instance(1)
    second = None
    try:
        second = Instance(2)
        initial = first.request("snapshot")
        assert initial["node"] == first.node
        assert initial["connection_string"].startswith("parvi://connect/v1?")
        assert second.request("snapshot")["node"] == second.node
        assert first.request("send", text="Hello from the native bridge 🐦")["error"] is None
        assert first.request("send", text="")["error"] is not None
        bad = first.request("connect", connection_string="not an invitation", request_id="bad-join")
        assert bad["error"] is not None and bad["request_id"] == "bad-join"
        invitation = second.request("snapshot")["connection_string"]
        joined = first.request("connect", connection_string=invitation, request_id="join-1")
        assert joined["error"] is None and joined["request_id"] == "join-1"
        await_state(first, lambda s: second.node in s["peers"])
        await_state(second, lambda s: first.node in s["peers"])
        await_state(first, lambda s: any(n["id"] == second.node and n["state"] == "running"
                                        for n in s["network"]["nodes"]))
        network = first.request("snapshot")["network"]
        assert sorted([first.node, second.node]) in network["edges"]
        first.request("send", text="First app to second app")
        await_state(second, lambda s: any(m["text"] == "First app to second app" for m in s["messages"]))
        second.request("send", text="Reply from second app")
        await_state(first, lambda s: any(m["text"] == "Reply from second app" for m in s["messages"]))
        departed_node = second.node
        second.close()
        second = None
        await_state(first, lambda s: s["peers"] == [])
        departed = await_state(first, lambda s: any(n["id"] == departed_node and n["state"] == "down"
                                                    for n in s["network"]["nodes"]))
        assert not departed["network"]["edges"]
        print("PASS: bundled runtime, invitation join, correlated errors, network status/topology, UTF-8, two-way chat and departure")
    finally:
        if second is not None:
            second.close()
        first.close()


if __name__ == "__main__":
    main()
