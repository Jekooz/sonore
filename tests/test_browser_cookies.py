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
