"""Real Windows DeviceWeb and Chromium: saved Session is current at startup.
No public Reception, audio, user identity or user settings are used.
"""
import importlib.util
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("shared_web", HERE / "shared-web-smoke.py")
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)

with tempfile.TemporaryDirectory(prefix="ba-web-rejoin-") as temporary:
    directory = Path(temporary)
    seed = secrets.token_hex(32)
    device = web.Device(directory, seed, core_ebin=web.CORE / "builds/intermediates/control/default/lib/ba_core/ebin",
                        assets=web.PRODUCT / "builds/WebApp")
    try:
        created = device.req("create_session", name="Gossip 1", desks=["ws://127.0.0.1:19999/relay/v1"])
        session = created["session"]["session"]
        first = device.req("snapshot")
        invitation = first["contacts"]["sessions"][session]["link"]
        assert invitation.startswith("beamaudio://s/")
        time.sleep(.5)  # Allow the normal settings writer to persist the invitation.
    finally:
        device.close()
    # Reproduce the owner's upgrade: the tab still has the pre-rename field.
    settings = directory / "settings.config"
    text = settings.read_text(encoding="utf-8")
    marker = "{open_sessions,"
    start = text.index(marker)
    end = text.index("}.", start) + 2
    entry = text[start:end]
    assert "session =>" in entry
    text = text[:start] + entry.replace("session =>", "buffee =>") + text[end:]
    settings.write_text(text, encoding="utf-8")
    device = web.Device(directory, seed, core_ebin=web.CORE / "builds/intermediates/control/default/lib/ba_core/ebin",
                        assets=web.PRODUCT / "builds/WebApp")
    try:
        # Verify the real HTTP endpoint before opening the real frontend.
        restored = device.req("snapshot")
        assert restored["device"] == first["device"]
        assert restored["session"]["session"] == session
        subprocess.run(["node", str(web.PRODUCT / "src/Apps/WebApp/tests/device-view-browser.mjs")],
            check=True, env=dict(os.environ, BA_TEST_DEVICE_URL=device.url, BA_TEST_EXPECT_SESSION=session), timeout=45)
        print("PASS: previous tab schema upgraded without losing Device identity or invitation", flush=True)
    finally:
        device.close()

    # The invitation in user settings is sufficient even without a return checkpoint.
    (directory / "session_connection.term").unlink()
    device = web.Device(directory, seed,
                        core_ebin=web.CORE / "builds/intermediates/control/default/lib/ba_core/ebin",
                        assets=web.PRODUCT / "builds/WebApp")
    try:
        assert device.req("snapshot")["session"]["state"] == "idle"
        subprocess.run(["node", str(web.PRODUCT / "src/Apps/WebApp/tests/device-view-browser.mjs")],
            check=True, env=dict(os.environ, BA_TEST_DEVICE_URL=device.url, BA_TEST_EXPECT_SESSION=session), timeout=45)
        print("PASS: user-settings invitation alone restores the previous Session as current", flush=True)
    finally:
        device.close()

    # Joining the compact invitation also works from an idle pre-rename tab.
    joining = directory / "joining"
    joining.mkdir()
    (joining / "settings.config").write_text(
        '{runtime,#{clock_reference => system}}.\n'
        '{open_sessions,[#{id => <<"default">>,name => <<"Session">>,buffee => null}]}.\n',
        encoding="utf-8")
    device = web.Device(joining, secrets.token_hex(32),
                        core_ebin=web.CORE / "builds/intermediates/control/default/lib/ba_core/ebin",
                        assets=web.PRODUCT / "builds/WebApp")
    try:
        joined = device.req("join_session", invitation=invitation)
        assert joined["session"]["session"] == session
        assert device.req("snapshot")["contacts"]["sessions"][session]["link"] == invitation
        print("PASS: compact invitation joins through real HTTP with an idle pre-rename tab", flush=True)
    finally:
        device.close()
