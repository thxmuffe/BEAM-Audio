"""Two disposable, non-distributed BEAM runtimes over the existing Reception Desk."""
import argparse
import json
import os
from pathlib import Path
import queue
import secrets
import shutil
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


class Runtime:
    def __init__(self, paths):
        env = dict(os.environ)
        # Never load app identities or remembered memberships/subscriptions.
        for key in ("PARVI_STATE_DIR", "PARVI_RELAY_CA_FILE", "PARVI_RECEPTION_DESK_URL"):
            env.pop(key, None)
        env["PARVI_IDENTITY_SEED"] = secrets.token_hex(32).upper()
        self.messages = queue.Queue()
        self.process = subprocess.Popen(
            [shutil.which("erl"), "+S", "2", "-noshell", "-pa", *map(str, paths),
             "-s", "parvi_swarm_control_probe", "main"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, text=True, encoding="utf-8")
        threading.Thread(target=self.read, daemon=True).start()
        self.identity = self.messages.get(timeout=10)

    def read(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except json.JSONDecodeError:
                pass

    def request(self, op, **fields):
        self.process.stdin.write(json.dumps(dict(op=op, **fields)) + "\n")
        self.process.stdin.flush()
        return self.messages.get(timeout=10)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def wait(runtime, predicate):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        snapshot = runtime.request("snapshot")
        if predicate(snapshot):
            return snapshot
        time.sleep(0.1)
    raise AssertionError("State did not converge: " + json.dumps(snapshot))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="wss://parvi-reception-desk.onrender.com/relay/v1")
    args = parser.parse_args()
    # Uses the same real Desk as the apps; does not start a separate service or GUI.
    paths = list((ROOT / "builds/intermediates/control/default/lib").glob("*/ebin"))
    assert paths, "Run rebar3 compile in src/control first"
    output = ROOT / "builds/intermediates/swarm-control-check"
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([shutil.which("erlc"), "-Werror", "-o", str(output),
                    str(Path(__file__).with_name("parvi_swarm_control_probe.erl"))], check=True)
    runtimes = []
    try:
        for _ in range(2):
            runtimes.append(Runtime([output, *paths]))
        a, b = runtimes
        swarm = secrets.token_hex(16).upper()
        for local, remote in ((a, b), (b, a)):
            assert local.request("configure", peer=remote.identity["id"],
                                 mailbox=remote.identity["mailbox"], swarm=swarm, url=args.url) == {"ok": True}
            wait(local, lambda s: s["relay"]["connected"])
        assert a.request("connect", peer=b.identity["id"]) == {"ok": True}
        for local, remote in ((a, b), (b, a)):
            peer = remote.identity["id"]
            wait(local, lambda s: s["sessions"].get(peer, {}).get("stage") == "authorized")
            assert local.request("read", peer=peer) == {
                "ok": True, "value": {"protocol": 1, "session": "authorized"}}
            caps = local.request("capabilities", peer=peer)
            assert caps["ok"] and caps["value"]["test"] == {
                "supported": True, "available": False, "requires_consent": True,
                "consent": False, "capacity": 2, "active": 0, "max_duration_ms": 10000}
        assert b.request("enable_test") == {"ok": True}
        assert a.request("capabilities", peer=b.identity["id"])["value"]["test"]["available"]
        before = b.request("snapshot")["rejected"]
        assert a.request("attack", peer=b.identity["id"]) == {"ok": True}
        wait(b, lambda s: s["rejected"] >= before + 3)
        assert a.request("read", peer=b.identity["id"])["ok"]
        for runtime in runtimes:
            s = runtime.request("snapshot")
            assert s["node"] == "nonode@nohost" and s["nodes"] == []
            assert not s["legacy_started"] and s["workers"] == 0
            assert s["children"] == ["parvi_device_sup", "parvi_swarm_control"]
        print("PASS: two independent runtimes, real Desk WSS, authenticated status and capability reads; "
              "local consent reflected; forbidden command, forged signer and replay rejected; "
              "no remote worker creation, OTP peers, audio or GUI")
    finally:
        for runtime in runtimes:
            runtime.close()


if __name__ == "__main__":
    main()
