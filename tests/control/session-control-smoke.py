"""Two disposable, non-distributed BEAM runtimes over the existing Reception Desk."""
import argparse
from collections import deque
import json
import os
from pathlib import Path
import queue
import secrets
import shutil
import subprocess
import threading
import tempfile
import time
import sys

ROOT = Path(__file__).resolve().parents[2]


class Runtime:
    def __init__(self, paths, seed=None, state=None, executable=None, extra_env=None):
        env = dict(os.environ)
        # Never load app identities or remembered memberships/subscriptions.
        for key in ("BA_STATE_DIR",):
            env.pop(key, None)
        self.state = tempfile.TemporaryDirectory() if state is None else None
        env["BA_STATE_DIR"] = state or self.state.name
        self.seed = seed or secrets.token_hex(32).upper()
        env["BA_IDENTITY_SEED"] = self.seed
        env.update(extra_env or {})
        self.messages = queue.Queue()
        self.process = subprocess.Popen(
            [executable or shutil.which("erl"), "+S", "2", "-noshell", "-pa", *map(str, paths),
             "-s", "ba_session_control_probe", "main"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, text=True, encoding="utf-8")
        self.stderr_lines=deque(maxlen=32)
        self.stderr_bytes=0
        threading.Thread(target=self.drain_stderr,daemon=True).start()
        threading.Thread(target=self.read, daemon=True).start()
        self.identity = self.messages.get(timeout=10)

    def drain_stderr(self):
        # A child must never block because its test harness left stderr unread.
        # Keep a bounded tail in memory; do not print transport credentials.
        for line in self.process.stderr:
            self.stderr_bytes+=len(line.encode('utf-8'))
            self.stderr_lines.append(line[-512:])

    def read(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except json.JSONDecodeError:
                if os.getenv("BA_TEST_VERBOSE"):
                    print(line.rstrip(),file=sys.stderr)

    def request(self, op, **fields):
        self.process.stdin.write(json.dumps(dict(op=op, **fields)) + "\n")
        self.process.stdin.flush()
        try:
            reply=self.messages.get(timeout=10)
        except queue.Empty as exc:
            raise TimeoutError(f'No reply to {op}; runtime exit={self.process.poll()}; stderr bytes drained={self.stderr_bytes}') from exc
        if op=='snapshot':
            assert reply.get('old_core_loaded') is False,'Old core modules loaded: '+str(reply)
        return reply

    def close(self):
        if self.process.poll() is not None:
            return
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
    parser.add_argument("--url", default="wss://beamaudio.onrender.com/reception")
    args = parser.parse_args()
    # Uses the same real Desk as the apps; does not start a separate service or GUI.
    paths = list((ROOT / "builds/intermediates/control/default/lib").glob("*/ebin"))
    assert paths, "Run rebar3 compile in src/control first"
    output = ROOT / "builds/intermediates/session-control-check"
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([shutil.which("erlc"), "-Werror", "-o", str(output),
                    str(Path(__file__).with_name("ba_session_control_probe.erl"))], check=True)
    runtimes = []
    try:
        for _ in range(2):
            runtimes.append(Runtime([output, *paths]))
        a, b = runtimes
        assert a.request("create", desks=[args.url])["ok"]
        wait(a, lambda s: all(d["connected"] for d in s["relay"]["desks"].values()))
        invitation = a.request("invite")["value"]
        assert b.request("join", invitation=invitation, desk=args.url)["ok"]
        wait(b, lambda s: s["membership"]["state"] == "authorized")
        assert a.request("grant", peer=b.identity["id"],
                         permissions=["capabilities_read", "status_read"])["ok"]
        revision = a.request("snapshot")["membership"]["revision"]
        wait(b, lambda s: s["membership"]["state"] == "authorized" and
             s["membership"]["revision"] == revision)
        assert a.request("connect", peer=b.identity["id"]) == {"ok": True}
        for local, remote in ((a, b), (b, a)):
            peer = remote.identity["id"]
            # Authentication starts an asynchronous capability/name read. Wait
            # for that read before issuing another request on the same session.
            wait(local, lambda s: s["links"].get(peer, {}).get("stage") == "authorized"
                 and peer in s["peer_names"])
            status = local.request("read", peer=peer)
            assert status == {"ok": True, "value": {"protocol": 1, "link": "authorized"}}, status
        before = b.request("snapshot")["rejected"]
        assert a.request("attack", peer=b.identity["id"]) == {"ok": True}
        wait(b, lambda s: s["rejected"] >= before + 3)
        assert a.request("read", peer=b.identity["id"])["ok"]
        for runtime in runtimes:
            s = runtime.request("snapshot")
            assert s["node"] == "nonode@nohost" and s["nodes"] == []
            assert not s["legacy_started"]
            assert s["children"] == sorted(["ba_contacts", "ba_device_config", "ba_desk_connections_sup", "ba_session", "ba_session_desks", "ba_sessions", "ba_settings", "ba_permission_pg"])
        print("PASS: status/capabilities over real Reception, signed and verified requests, link authorization and attack rejection")
    finally:
        for runtime in runtimes:
            runtime.close()


if __name__ == "__main__":
    main()
