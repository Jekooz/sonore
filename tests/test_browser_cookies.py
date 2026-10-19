"""
Unit + protocol coverage for the dependency-free cookie capture.

Two things here are worth real tests because nothing else exercises them:

* the DevTools WebSocket client — the handshake, masked client frames, and
  server frames that are fragmented and use the 16- and 64-bit length forms.
  A throwaway socket server speaks enough RFC 6455 to answer one CDP command,
  so this runs against the real client rather than a mock of it.
* the Firefox reader — a real ``moz_cookies`` SQLite file in a tmp profile.
"""

import base64
import hashlib
import json
import os
import socket
import sqlite3
import struct
import sys
import threading
import time

import pytest

BACKEND_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "backend"
)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from services import browser_cookies as bc  # noqa: E402

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# --------------------------------------------------------------- CDP filtering


def test_cdp_cookies_keep_only_youtube_and_google_hosts():
    jar = bc._cookies_from_cdp([
        {"name": "SID", "value": "s", "domain": ".google.com"},
        {"name": "__Secure-3PAPISID", "value": "p", "domain": ".youtube.com"},
        {"name": "csrftoken", "value": "nope", "domain": ".example.com"},
        {"name": "locale", "value": "nope", "domain": ".instagram.com"},
        {"name": "HSID", "value": "h", "domain": "music.youtube.com"},
    ])

    assert jar == {"SID": "s", "__Secure-3PAPISID": "p", "HSID": "h"}


def test_cdp_cookies_ignore_malformed_entries_and_empty_values():
    jar = bc._cookies_from_cdp([
        "not a dict",
        {"name": "SID", "domain": ".google.com"},           # no value
        {"value": "x", "domain": ".google.com"},            # no name
        {"name": "SAPISID", "value": "ok", "domain": ".google.com"},
    ])

    assert jar == {"SAPISID": "ok"}


# --------------------------------------------------------------- Firefox reader


def _make_firefox_profile(root, rows):
    profile = os.path.join(root, "abc123.default-release")
    os.makedirs(profile, exist_ok=True)
    connection = sqlite3.connect(os.path.join(profile, "cookies.sqlite"))
    connection.execute(
        "CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, name TEXT, value TEXT, host TEXT)"
    )
    connection.executemany("INSERT INTO moz_cookies (name, value, host) VALUES (?,?,?)", rows)
    connection.commit()
    connection.close()
    return profile


def test_firefox_cookies_are_read_and_filtered(tmp_path, monkeypatch):
    profile = _make_firefox_profile(
        str(tmp_path),
        [
            ("SID", "s", ".google.com"),
            ("__Secure-3PAPISID", "p", ".youtube.com"),
            ("_ga", "ignored", ".google-analytics.com"),
            ("csrftoken", "ignored", ".example.com"),
        ],
    )
    monkeypatch.setattr(bc, "_firefox_profile_dirs", lambda: iter([profile]))

    jar = bc.cookies_from_firefox()

    assert jar == {"SID": "s", "__Secure-3PAPISID": "p"}


def test_firefox_without_a_session_is_not_a_jar(tmp_path, monkeypatch):
    profile = _make_firefox_profile(
        str(tmp_path), [("csrftoken", "ignored", ".example.com")]
    )
    monkeypatch.setattr(bc, "_firefox_profile_dirs", lambda: iter([profile]))

    assert bc.cookies_from_firefox() is None


def test_firefox_prefers_the_profile_that_is_signed_in(tmp_path, monkeypatch):
    # Two profiles is normal. The anonymous one comes first on purpose: its
    # YouTube cookies must not shadow the session in the other.
    anonymous = _make_firefox_profile(
        str(tmp_path / "anon"),
        [("VISITOR_INFO1_LIVE", "v", ".youtube.com")],
    )
    signed_in = _make_firefox_profile(
        str(tmp_path / "real"),
        [("SID", "s", ".google.com"), ("SAPISID", "p", ".google.com")],
    )
    monkeypatch.setattr(
        bc, "_firefox_profile_dirs", lambda: iter([anonymous, signed_in])
    )

    assert bc.cookies_from_firefox() == {"SID": "s", "SAPISID": "p"}


def test_firefox_falls_back_to_the_first_jar_when_none_is_signed_in(
    tmp_path, monkeypatch
):
    # No profile carries SID, so the first non-empty jar is handed on and the
    # caller's own validation decides what to do with it.
    first = _make_firefox_profile(
        str(tmp_path / "one"), [("VISITOR_INFO1_LIVE", "v", ".youtube.com")]
    )
    second = _make_firefox_profile(
        str(tmp_path / "two"), [("PREF", "p", ".youtube.com")]
    )
    monkeypatch.setattr(bc, "_firefox_profile_dirs", lambda: iter([first, second]))

    assert bc.cookies_from_firefox() == {"VISITOR_INFO1_LIVE": "v"}


def test_firefox_profile_with_no_cookie_db_is_skipped(tmp_path, monkeypatch):
    empty = tmp_path / "empty.default"
    empty.mkdir()
    monkeypatch.setattr(bc, "_firefox_profile_dirs", lambda: iter([str(empty)]))

    assert bc.cookies_from_firefox() is None


# --------------------------------------------------------------- WebSocket


def _read_exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise ConnectionError("client closed")
        data += chunk
    return data


def _read_client_frame(conn):
    first, second = _read_exact(conn, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack(">H", _read_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", _read_exact(conn, 8))[0]
    mask = _read_exact(conn, 4)
    payload = bytearray(_read_exact(conn, length))
    for i in range(length):
        payload[i] ^= mask[i % 4]
    assert first & 0x0F == 0x1, "the client must send a text frame"
    assert second & 0x80, "client frames must be masked"
    return bytes(payload)


def _frame(fin, opcode, payload):
    header = bytearray([(0x80 if fin else 0x00) | opcode])
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += struct.pack(">H", length)
    else:
        header.append(127)
        header += struct.pack(">Q", length)
    return bytes(header) + payload


def _ws_server(reply_text):
    """A one-shot RFC 6455 server that answers one CDP command."""
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    state = {"error": None, "command": None}

    def serve():
        try:
            conn, _ = server.accept()
            conn.settimeout(5)
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                request += chunk
            key = ""
            for line in request.split(b"\r\n"):
                if line.lower().startswith(b"sec-websocket-key:"):
                    key = line.split(b":", 1)[1].strip().decode("ascii")
            accept = base64.b64encode(
                hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
            ).decode("ascii")
            conn.sendall(
                (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                ).encode("ascii")
            )
            state["command"] = json.loads(_read_client_frame(conn).decode("utf-8"))

            # Split the reply so the client has to reassemble continuation
            # frames, and make the middle one large enough to need the 64-bit
            # length form.
            payload = reply_text.encode("utf-8")
            head, middle, tail = payload[:97], payload[97:97 + 70000], payload[97 + 70000:]
            conn.sendall(_frame(False, 0x1, head))
            conn.sendall(_frame(False, 0x0, middle))
            conn.sendall(_frame(True, 0x0, tail))
            time.sleep(0.1)
            conn.close()
        except Exception as e:  # noqa: BLE001 - surfaced through state
            state["error"] = repr(e)
        finally:
            server.close()

    threading.Thread(target=serve, daemon=True).start()
    return port, state


def test_read_devtools_cookies_reassembles_a_large_fragmented_reply(monkeypatch):
    cookies = [
        {"name": "SID", "value": "s" * 300, "domain": ".google.com"},
        {"name": "__Secure-3PAPISID", "value": "p" * 300, "domain": ".youtube.com"},
        {"name": "noise", "value": "n" * 70000, "domain": ".example.com"},
    ]
    reply = json.dumps({"id": 1, "result": {"cookies": cookies}})
    port, state = _ws_server(reply)

    monkeypatch.setattr(
        bc,
        "_http_json",
        lambda url, timeout=3.0: {
            "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/browser/xyz"
        },
    )

    jar = bc.read_devtools_cookies(port, deadline=time.monotonic() + 5)

    assert state["error"] is None, state["error"]
    assert state["command"]["method"] == "Storage.getCookies"
    assert jar == {
        "SID": "s" * 300,
        "__Secure-3PAPISID": "p" * 300,
    }


def test_read_devtools_cookies_falls_back_to_network_get_all_cookies(monkeypatch):
    """Older builds reject Storage.getCookies with a CDP error object."""
    port, state = _ws_server_error_then_ok()
    monkeypatch.setattr(
        bc,
        "_http_json",
        lambda url, timeout=3.0: {
            "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/browser/xyz"
        },
    )

    jar = bc.read_devtools_cookies(port, deadline=time.monotonic() + 5)

    assert state["error"] is None, state["error"]
    assert jar == {"SID": "s"}


def _ws_server_error_then_ok():
    """A server that errors on the first command and answers the second."""
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]
    state = {"error": None}

    def serve():
        try:
            conn, _ = server.accept()
            conn.settimeout(5)
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                request += chunk
            key = ""
            for line in request.split(b"\r\n"):
                if line.lower().startswith(b"sec-websocket-key:"):
                    key = line.split(b":", 1)[1].strip().decode("ascii")
            accept = base64.b64encode(
                hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
            ).decode("ascii")
            conn.sendall(
                (
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\n"
                    "Connection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                ).encode("ascii")
            )
            # The client may open a second connection after the first refusal;
            # this server handles both on the same socket only if the caller
            # reuses it, which read_devtools_cookies does not. So: answer the
            # first command with an error and the second with a jar, keeping the
            # socket open across both.
            first = json.loads(_read_client_frame(conn).decode("utf-8"))
            conn.sendall(_frame(True, 0x1, json.dumps(
                {"id": first["id"], "error": {"message": "method not found"}}
            ).encode("utf-8")))

            # read_devtools_cookies retries on the SAME socket
            second = json.loads(_read_client_frame(conn).decode("utf-8"))
            conn.sendall(_frame(True, 0x1, json.dumps({
                "id": second["id"],
                "result": {
                    "cookies": [
                        {"name": "SID", "value": "s", "domain": ".google.com"},
                    ]
                },
            }).encode("utf-8")))
            time.sleep(0.1)
            conn.close()
        except Exception as e:  # noqa: BLE001
            state["error"] = repr(e)
        finally:
            server.close()

    threading.Thread(target=serve, daemon=True).start()
    return port, state


# ------------------------------------------------- which browser sign-in uses
#
# The point of this section: sign-in must follow the browser the user chose in
# Windows, not a vendor preference. The decision is one function, and these pin
# every branch of it without touching this machine's real registry or files.

def _install_with_version_folder(root, exe_name="somebrowser.exe"):
    """A Chromium-style install: the exe beside a numbered version folder."""
    (root / "154.0.8037.181").mkdir(parents=True, exist_ok=True)
    exe = root / exe_name
    exe.write_bytes(b"")
    return str(exe)


def test_the_executable_is_read_out_of_a_shell_open_command(tmp_path):
    exe = tmp_path / "comet.exe"
    exe.write_bytes(b"")

    # The forms Windows actually registers: quoted with arguments, and bare.
    assert bc._exe_from_command(f'"{exe}" --single-argument %1') == str(exe)
    assert bc._exe_from_command(f'{exe} "%1"') == str(exe)
    assert bc._exe_from_command('"C:\\nowhere\\missing.exe" %1') is None
    assert bc._exe_from_command("") is None


def test_the_default_browser_is_named_from_its_progid(monkeypatch, tmp_path):
    exe = tmp_path / "comet.exe"
    exe.write_bytes(b"")
    monkeypatch.setattr(bc, "_userchoice_progid", lambda: "CometHTM")
    monkeypatch.setattr(
        bc, "_progid_command", lambda progid: f'"{exe}" --single-argument %1'
    )

    assert bc.default_browser() == ("Comet", str(exe))


def test_a_browser_nobody_listed_is_named_from_its_executable(
    monkeypatch, tmp_path
):
    """A new browser still gets a name, so the prompt never says 'unknown'."""
    exe = tmp_path / "zen-browser.exe"
    exe.write_bytes(b"")
    monkeypatch.setattr(bc, "_userchoice_progid", lambda: "ZenHTML.9f2c")
    monkeypatch.setattr(bc, "_progid_command", lambda progid: f'"{exe}" %1')

    assert bc.default_browser() == ("Zen Browser", str(exe))


def test_no_association_means_no_default_browser(monkeypatch):
    monkeypatch.setattr(bc, "_userchoice_progid", lambda: "")
    assert bc.default_browser() is None


def test_firefox_is_recognised_by_name_and_by_executable():
    assert bc.is_firefox("Mozilla Firefox", r"C:\Firefox\firefox.exe")
    assert bc.is_firefox("Waterfox", r"C:\Waterfox\waterfox.exe")
    assert bc.is_firefox("", r"C:\x\firefox.exe")
    assert not bc.is_firefox("Comet", r"C:\Comet\comet.exe")


def test_a_numbered_version_folder_means_chromium_is_drivable(tmp_path):
    """How an unlisted browser (Comet) is known to be drivable at all."""
    assert bc.is_probably_chromium(_install_with_version_folder(tmp_path))


def test_a_firefox_shaped_install_is_not_drivable(tmp_path):
    install = tmp_path / "Firefox"
    (install / "defaults").mkdir(parents=True)
    exe = install / "somebrowser.exe"
    exe.write_bytes(b"")

    assert not bc.is_probably_chromium(str(exe))
    assert not bc.is_probably_chromium("")


def test_a_known_chromium_browser_needs_no_folder_check(tmp_path):
    assert bc.is_probably_chromium(str(tmp_path / "brave.exe"))


def test_the_default_browser_is_the_first_candidate(monkeypatch, tmp_path):
    exe = _install_with_version_folder(tmp_path, "comet.exe")
    monkeypatch.setattr(bc, "default_browser", lambda: ("Comet", exe))
    monkeypatch.setattr(
        bc, "_app_paths_key",
        lambda name: {
            "msedge.exe": r"C:\Edge\msedge.exe",
            "chrome.exe": r"C:\Chrome\chrome.exe",
        }.get(name),
    )
    monkeypatch.setattr(bc, "_known_install", lambda exe_name, subdirs: None)

    assert bc.controllable_browsers() == [
        ("Comet", exe),
        ("Microsoft Edge", r"C:\Edge\msedge.exe"),
        ("Google Chrome", r"C:\Chrome\chrome.exe"),
    ]


def test_a_browser_that_is_already_the_default_is_not_listed_twice(monkeypatch):
    monkeypatch.setattr(
        bc, "default_browser", lambda: ("Microsoft Edge", r"C:\Edge\msedge.exe")
    )
    monkeypatch.setattr(
        bc, "_app_paths_key",
        lambda name: r"C:\Edge\msedge.exe" if name == "msedge.exe" else None,
    )
    monkeypatch.setattr(bc, "_known_install", lambda exe_name, subdirs: None)

    assert bc.controllable_browsers() == [
        ("Microsoft Edge", r"C:\Edge\msedge.exe"),
    ]


def test_firefox_is_never_a_candidate(monkeypatch):
    """It is read from its own profile, not driven."""
    monkeypatch.setattr(
        bc, "default_browser", lambda: ("Mozilla Firefox", r"C:\Firefox\firefox.exe")
    )
    monkeypatch.setattr(bc, "_app_paths_key", lambda name: None)
    monkeypatch.setattr(bc, "_known_install", lambda exe_name, subdirs: None)

    assert bc.controllable_browsers() == []


def test_the_plan_reads_a_default_firefox_profile(monkeypatch, tmp_path):
    profile = tmp_path / "abc123.default-release"
    profile.mkdir()
    (profile / "cookies.sqlite").write_bytes(b"")
    monkeypatch.setattr(bc, "_firefox_profile_dirs", lambda: iter([str(profile)]))
    monkeypatch.setattr(
        bc, "default_browser", lambda: ("Mozilla Firefox", r"C:\Firefox\firefox.exe")
    )

    assert bc.sign_in_plan() == ("firefox", "Mozilla Firefox")


def test_the_plan_drives_a_chromium_default(monkeypatch, tmp_path):
    exe = _install_with_version_folder(tmp_path, "comet.exe")
    monkeypatch.setattr(bc, "_firefox_profile_dirs", lambda: iter([]))
    monkeypatch.setattr(bc, "default_browser", lambda: ("Comet", exe))
    monkeypatch.setattr(bc, "_app_paths_key", lambda name: None)
    monkeypatch.setattr(
        bc, "_known_install", lambda exe_name, subdirs: r"C:\Edge\msedge.exe"
    )

    assert bc.sign_in_plan() == ("devtools", "Comet")


def test_the_plan_falls_back_to_edge_when_the_default_cannot_be_driven(
    monkeypatch, tmp_path
):
    exotic = tmp_path / "exoticbrowser.exe"
    exotic.write_bytes(b"")
    monkeypatch.setattr(bc, "_firefox_profile_dirs", lambda: iter([]))
    monkeypatch.setattr(bc, "default_browser", lambda: ("Exotic", str(exotic)))
    monkeypatch.setattr(
        bc, "_app_paths_key",
        lambda name: r"C:\Edge\msedge.exe" if name == "msedge.exe" else None,
    )
    monkeypatch.setattr(bc, "_known_install", lambda exe_name, subdirs: None)

    assert bc.sign_in_plan() == ("devtools", "Microsoft Edge")


def test_the_plan_admits_when_nothing_can_be_read(monkeypatch, tmp_path):
    """No drivable browser at all: the caller must fail, not open a window."""
    exotic = tmp_path / "exoticbrowser.exe"
    exotic.write_bytes(b"")
    monkeypatch.setattr(bc, "_firefox_profile_dirs", lambda: iter([]))
    monkeypatch.setattr(bc, "default_browser", lambda: ("Exotic", str(exotic)))
    monkeypatch.setattr(bc, "_app_paths_key", lambda name: None)
    monkeypatch.setattr(bc, "_known_install", lambda exe_name, subdirs: None)

    assert bc.sign_in_plan() == ("shell", "Exotic")


def test_each_browser_gets_a_profile_of_its_own():
    """Two browsers must never share one Chromium profile directory."""
    assert bc._profile_for("C:\\profiles", r"C:\Comet\comet.exe") == os.path.join(
        "C:\\profiles", "comet"
    )
    assert bc._profile_for("C:\\profiles", r"C:\Edge\msedge.exe") == os.path.join(
        "C:\\profiles", "msedge"
    )


def test_a_candidate_that_will_not_start_falls_through_to_the_next(
    monkeypatch, tmp_path
):
    """A build that refuses the debugging port must not cost a working one."""
    attempts = []
    monkeypatch.setattr(
        bc, "controllable_browsers",
        lambda: [
            ("Comet", r"C:\Comet\comet.exe"),
            ("Microsoft Edge", r"C:\Edge\msedge.exe"),
        ],
    )

    def launch_one(name, exe, url, profile_dir):
        attempts.append(name)
        if name == "Comet":
            raise bc.BrowserLaunchError("it did not open a debugging port in time")
        return 4321

    monkeypatch.setattr(bc, "_launch_one", launch_one)

    assert bc.launch_controllable_browser(
        "https://music.youtube.com", str(tmp_path)
    ) == ("Microsoft Edge", 4321)
    assert attempts == ["Comet", "Microsoft Edge"]


def test_no_browser_that_starts_says_where_to_go_instead(monkeypatch, tmp_path):
    monkeypatch.setattr(
        bc, "controllable_browsers", lambda: [("Comet", r"C:\Comet\comet.exe")]
    )
    monkeypatch.setattr(
        bc, "_launch_one",
        lambda *a: (_ for _ in ()).throw(bc.BrowserLaunchError("nope")),
    )

    with pytest.raises(bc.BrowserLaunchError) as refused:
        bc.launch_controllable_browser("https://music.youtube.com", str(tmp_path))

    assert "Comet" in str(refused.value)
    assert "Settings" in str(refused.value)


# ------------------------------------------------- a profile that is set up
#
# A fresh Chromium profile runs its vendor's first-run wizard, and the profile
# this app opens is always fresh. Comet's wizard is its own page, so the sign-in
# page never loaded and the attempt could only time out -- the seed below is the
# fix, and what these tests pin is that it stays narrow.

def _local_state(profile_dir):
    with open(os.path.join(str(profile_dir), "Local State"), encoding="utf-8") as f:
        return json.load(f)


def test_a_fresh_profile_is_marked_as_already_set_up(tmp_path):
    bc._seed_profile(str(tmp_path), r"C:\Program Files\Perplexity\Comet\comet.exe")

    state = _local_state(tmp_path)
    assert state["browser"]["first_run_finished"] is True
    assert state["perplexity"]["onboarding_completed"] is True


def test_seeding_a_profile_never_discards_its_encryption_keys(tmp_path):
    """The merge is the point: replacing Local State would strand a session."""
    (tmp_path / "Local State").write_text(
        json.dumps(
            {
                "os_crypt": {"encrypted_key": "DPAPI-kept", "audit_enabled": False},
                "unrelated": {"kept": True},
            }
        ),
        encoding="utf-8",
    )

    bc._seed_profile(str(tmp_path), r"C:\x\comet.exe")

    state = _local_state(tmp_path)
    assert state["os_crypt"]["encrypted_key"] == "DPAPI-kept"
    assert state["unrelated"]["kept"] is True
    assert state["perplexity"]["onboarding_completed"] is True
    assert state["browser"]["first_run_finished"] is True


def test_a_browser_with_no_wizard_gets_only_the_stock_flag(tmp_path):
    bc._seed_profile(str(tmp_path), r"C:\Edge\msedge.exe")

    state = _local_state(tmp_path)
    assert state == {"browser": {"first_run_finished": True}}


def test_unreadable_local_state_is_replaced_rather_than_fatal(tmp_path):
    (tmp_path / "Local State").write_text("{not json", encoding="utf-8")

    bc._seed_profile(str(tmp_path), r"C:\x\comet.exe")

    assert _local_state(tmp_path)["perplexity"]["onboarding_completed"] is True


def test_a_launch_seeds_before_starting_the_browser(monkeypatch, tmp_path):
    """The flags have to be on disk before the process reads them."""
    seen = {}

    def fake_popen(args, **kwargs):
        seen["local_state"] = os.path.isfile(
            os.path.join(str(tmp_path), "Local State")
        )
        raise OSError("stop here")

    monkeypatch.setattr(bc.subprocess, "Popen", fake_popen)
    with pytest.raises(bc.BrowserLaunchError):
        bc._launch_one("Comet", r"C:\Comet\comet.exe", "https://x", str(tmp_path))

    assert seen["local_state"] is True
