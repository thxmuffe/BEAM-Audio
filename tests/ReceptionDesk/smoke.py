"""Real HTTP directory + two app runtimes; no third-party Python packages."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/macOS"))
from smoke import Instance, await_state

with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
base = f"http://127.0.0.1:{port}"
env = dict(os.environ, PARVI_BROKER_BIND="127.0.0.1", PARVI_BROKER_PORT=str(port))


def start():
    process = subprocess.Popen(["bash", "src/Services/ReceptionDesk/run-legacy.sh"], cwd=ROOT, env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(150):
        try:
            if call()[0] == 200:
                return process
        except (OSError, urllib.error.URLError):
            pass
        if process.poll() is not None:
            raise RuntimeError("Test broker failed to start")
        time.sleep(0.05)
    process.terminate()
    process.wait(timeout=5)
    raise TimeoutError("Test broker startup")


def call(body=None, method=None, content_type="application/json", path="/api/nodes"):
    request = urllib.request.Request(base + path, data=body, method=method,
                                     headers={"Content-Type": content_type})
    try:
        response = urllib.request.urlopen(request, timeout=3)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.read()


broker = start()
first = second = None
web = None
try:
    assert json.loads(call()[1]) == {"node_ids": []}
    assert json.loads(call(path="/")[1])["service"] == "ReceptionDesk"
    assert call(path="/qrcode.js")[0] == 404
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        web_port = probe.getsockname()[1]
    web = subprocess.Popen(["bash", "src/Apps/WebApp/run.sh"], cwd=ROOT,
                           env=dict(os.environ, PARVI_WEBAPP_PORT=str(web_port),
                                    PARVI_RECEPTION_DESK_URL=base),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{web_port}/", timeout=2) as response:
                assert b"Parvi WebApp" in response.read()
            break
        except urllib.error.URLError:
            time.sleep(0.05)
    else:
        raise TimeoutError("WebApp startup")
    for asset in ["app.js", "style.css", "qrcode.js"]:
        with urllib.request.urlopen(f"http://127.0.0.1:{web_port}/{asset}") as response:
            assert response.status == 200
    with urllib.request.urlopen(f"http://127.0.0.1:{web_port}/api/nodes") as response:
        assert json.load(response) == {"node_ids": []}
    assert call(b"not json")[0] == 400
    assert call(b'{}')[0] == 400
    assert call(b'{"node_id":"x@host"}', content_type="text/plain")[0] == 415
    assert call(method="DELETE")[0] == 405
    assert call(b"x" * 2048)[0] == 413
    first, second = Instance(1), Instance(2)
    initial = first.request("discover", url=base)
    assert initial["error"] is None, initial
    discovered = second.request("discover", url=base)
    assert discovered["error"] is None
    assert discovered["known_nodes"] == [first.node]
    refreshed = first.request("discover", url=base)
    assert refreshed["known_nodes"] == [second.node]
    assert len(json.loads(call()[1])["node_ids"]) == 2  # refresh deduplicates
    assert first.request("connect", node=second.node, cookie=second.cookie)["error"] is None
    await_state(first, lambda s: second.node in s["peers"])
    first.request("send", text="Found through the local directory")
    await_state(second, lambda s: any(m["text"] == "Found through the local directory" for m in s["messages"]))
    second.request("send", text="Handshake and reply confirmed")
    await_state(first, lambda s: any(m["text"] == "Handshake and reply confirmed" for m in s["messages"]))
    broker.terminate()
    broker.wait(timeout=5)
    broker = start()
    assert json.loads(call()[1])["node_ids"] == []
    print("PASS: HTTP API, validation, duplicate registration, app discovery, Erlang handshake, two-way chat, restart clears names")
finally:
    if web is not None:
        web.terminate()
        web.wait(timeout=5)
    for instance in (first, second):
        if instance is not None:
            instance.close()
    broker.terminate()
    broker.wait(timeout=5)
