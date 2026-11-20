"""Exercise the packaged Windows host, shared HTTP API and local Reception.
Build OpenSound (build.sh or Build.cmd) first. All identities/state disposable.
Optional --invitation-file checks admission to a supplied Session without chat.
"""
from pathlib import Path
import argparse, importlib.util, json, os, queue, re, secrets, socket, subprocess, tempfile, threading, time
import urllib.request

CORE = Path(__file__).resolve().parents[2]
PRODUCT = Path(os.environ.get("OPENSOUND_ROOT", CORE.parent / "OpenSound"))
APP = PRODUCT / "builds/Windows/OpenSound"
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))

class Device:
    def __init__(self, directory, seed, *, core_ebin=None, assets=None):
        self.directory, self.seed = directory, seed
        directory.mkdir(parents=True, exist_ok=True)
        settings = directory / "settings.config"
        if not settings.exists():
            settings.write_text("{runtime,#{clock_reference => system}}.\n")
        self.lines = queue.Queue()
        self.process = subprocess.Popen([
            str(APP / "runtime/bin/erl.exe"), "+S", "2", "-noshell", "-noinput",
            "-pa", str(APP / "ebin"), *(["-pa", str(core_ebin)] if core_ebin else []),
            "-s", "os_windows_host", "boot", "-extra",
            "--assets", str(assets or APP / "assets"), "--port", "0", "--local-device"
        ], cwd=APP, env=dict(os.environ, BA_STATE_DIR=str(directory), BA_IDENTITY_SEED=seed,
                           ERL_LIBS=str(APP / "lib")),
           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        def read():
            for line in self.process.stdout:
                self.lines.put(line)
        threading.Thread(target=read, daemon=True).start()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try: line = self.lines.get(timeout=.5)
            except queue.Empty:
                if self.process.poll() is not None: raise AssertionError("Windows host exited during startup")
                continue
            match = re.search(r"BEAM Audio: (http://127\.0\.0\.1:\d+)", line)
            if match:
                self.url = match[1]
                self.token = self.get("/api/session")["token"]
                return
        self.close()
        raise AssertionError("Windows host did not publish its local URL")

    def get(self, path):
        with HTTP.open(self.url + path, timeout=5) as response:
            return json.load(response)

    def req(self, method, **values):
        request = urllib.request.Request(self.url + "/api/command",
            data=json.dumps(dict(method=method, **values)).encode(),
            headers={"Content-Type": "application/json", "X-BEAM-Audio-Token": self.token,
                     "Origin": self.url})
        with HTTP.open(request, timeout=35) as response: result = json.load(response)
        assert not result.get("error"), result.get("error")
        return result

    def wait(self, predicate, seconds=35, **values):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            state = self.req("snapshot", **values)
            if predicate(state): return state
            time.sleep(.25)
        # Deliberately exclude invitations, credentials and chat from failures.
        raise AssertionError(json.dumps(summary(state)))

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=10)
        self.process.stdout.close()


def summary(state):
    return dict(state=state.get("session", {}).get("state"),
                connection=state.get("connection"),
                devices=[dict(local=d.get("local"), state=d.get("state")) for d in state.get("devices", [])],
                desks=[dict(connected=d.get("connected"), error=d.get("error"), diagnostics=d.get("diagnostics"))
                       for d in state.get("desks", {}).get("desks", {}).values()])


def connected(state):
    return len(state.get("devices", [])) >= 2 and all(d["state"] == "authorized" for d in state["devices"])


def browser_lifetime(directory):
    # A deterministic app process exercises the real CLI lifetime contract
    # without moving the user's mouse or opening a browser during this test.
    # BA_WEB_BROWSER replaces Chrome/Edge; a .py stand-in runs under Python.
    script = directory / "browser-lifetime.py"
    script.write_text("import os, sys, time\n"
        "if not sys.argv[1].startswith('--app=') or os.environ.get('BA_IDENTITY_SEED'): sys.exit(9)\n"
        "time.sleep(0.6)\n")
    state = directory / "lifetime"
    completed = subprocess.run([str(APP/"runtime/bin/erl.exe"), "+S", "2", "-noshell", "-noinput",
        "-pa", str(APP/"ebin"), "-s", "ba_device_web_cli", "main", "-extra", "--assets",
        str(APP/"assets"), "--port", "0", "--local-device", "--app"],
        cwd=APP, env=dict(os.environ, BA_STATE_DIR=str(state), BA_IDENTITY_SEED=secrets.token_hex(32),
            ERL_LIBS=str(APP/"lib"), BA_WEB_BROWSER=str(script)),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=25)
    assert completed.returncode == 0, "App lifetime did not shut down cleanly"
    assert (state/"settings.config").exists(), "App close did not flush Device settings"
    print("PASS: app process exit shuts down Device and saves settings; browser inherits no identity seed", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--invitation-file", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ba-windows-web-") as temporary:
        devices = []
        desk = None
        try:
            browser_lifetime(Path(temporary))
            if not args.invitation_file:
                spec = importlib.util.spec_from_file_location("relay", CORE/"tests/ReceptionDesk/local_reception.py")
                relay = importlib.util.module_from_spec(spec); spec.loader.exec_module(relay)
                with socket.socket() as probe:
                    probe.bind(("127.0.0.1", 0)); port = probe.getsockname()[1]
                desk = relay.start_desk(port)
                desk_url = f"ws://127.0.0.1:{port}/relay/v1"
            a = Device(Path(temporary)/"a", secrets.token_hex(32)); devices.append(a)
            b = Device(Path(temporary)/"b", secrets.token_hex(32)); devices.append(b)
            sa, sb = a.req("snapshot"), b.req("snapshot")
            assert sa["profile"] == sb["profile"] == "session_control"
            assert sa["device"] != sb["device"] and a.url != b.url
            assert not any(sa["consent"].get(k) for k in ("microphone", "speaker", "broadcast"))
            for asset in (APP / "assets").iterdir():
                original = PRODUCT/"src/Apps/WebApp/public"/asset.name
                if original.is_file():
                    if asset.name == "index.html":
                        # Packaging stamps the version; all other page content
                        # must still match the shared frontend source.
                        packaged = re.sub(r"Version 0\.\d+", "Version development", asset.read_text(encoding="utf-8"))
                        assert packaged == original.read_text(encoding="utf-8"), asset.name
                    else:
                        assert asset.read_bytes() == original.read_bytes(), asset.name
            print("PASS: packaged shared frontend, isolated Devices/ports, audio consent off", flush=True)
            if args.invitation_file:
                invitation = args.invitation_file.read_text().strip()
                for device in (a, b): device.req("join_session", invitation=invitation)
                for device in (a, b):
                    other = sb["device"] if device is a else sa["device"]
                    state = device.wait(lambda s: s["session"]["state"] == "authorized" and
                        any(d["id"] == other and d["state"] == "authorized" for d in s["devices"]), seconds=65)
                    print("PASS: supplied invitation, authorized peer visibility: " + json.dumps(summary(state)), flush=True)
                return
            a.req("create_session", name="Windows integration check", desks=[desk_url])
            a.wait(lambda s: any(d.get("connected") for d in s["desks"]["desks"].values()))
            invitation = a.req("invitation")["result"]
            b.req("join_session", invitation=invitation)
            a.wait(connected); b.wait(connected)
            print("PASS: two packaged Windows Devices see each other through local Reception", flush=True)
            a.req("send", text="Windows isolated integration check")
            b.wait(lambda s: any(m.get("text") == "Windows isolated integration check" for m in s["messages"]))
            print("PASS: authenticated chat delivered through shared runtime", flush=True)
            old_id = b.req("snapshot")["device"]
            time.sleep(.5)
            b.close()
            b = Device(b.directory, b.seed); devices.append(b)
            assert b.req("snapshot")["device"] == old_id
            b.wait(connected)
            print("PASS: Device identity and joined Session survive runtime restart", flush=True)
            # Both endpoints lose their live mailboxes: the permanent link must
            # still find the creator, including a newly admitted third Device.
            a.close(); b.close()
            a = Device(a.directory, a.seed); devices.append(a)
            b = Device(b.directory, b.seed); devices.append(b)
            a.wait(connected, seconds=65); b.wait(connected, seconds=65)
            c = Device(Path(temporary)/"c", secrets.token_hex(32)); devices.append(c)
            c.req("join_session", invitation=invitation)
            c.wait(lambda s: s["session"]["state"] == "authorized" and len(s["devices"]) == 3 and connected(s))
            a.wait(connected); b.wait(connected)
            print("PASS: both endpoints restart; the original invitation admits a new Device", flush=True)
            # Match Home's Join path while another Session is already active.
            slot = a.req("new_session")["session_id"]
            a.req("create_session", session=slot, name="Second local Session", desks=[desk_url])
            link2 = a.req("invitation", session=slot)["result"]
            blank = b.req("new_session")["session_id"]
            joined = b.req("join_session", session=blank, invitation=link2)["session_id"]
            a.wait(connected, session=slot); b.wait(connected, session=joined)
            b.wait(lambda s: len(s["devices"]) == 3 and connected(s), session="default")
            again = b.req("new_session")["session_id"]
            result = b.req("join_session", session=again, invitation=link2)
            assert result["session_id"] == joined and len(result["sessions"]) == 2
            print("PASS: join into a second Session, original peers retained, repeat join deduplicated", flush=True)
        finally:
            for device in reversed(devices): device.close()
            if desk is not None:
                desk.terminate(); desk.wait(timeout=10)

if __name__ == "__main__": main()
