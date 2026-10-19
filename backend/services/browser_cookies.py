"""
Cookie capture that needs no browser extension and no extra packages.

YouTube Music has no usable OAuth for third-party apps (Google disabled the
device-code flow), so the only session source is a browser's cookies. Those are
deliberately hard to reach:

  * ``SID``, ``SAPISID`` and ``__Secure-3PAPISID`` are HttpOnly, so page script
    cannot read them.
  * Chrome/Edge/Brave encrypt their cookie DB with App-Bound Encryption, so a
    plain file read (what ``rookiepy`` used to do) no longer works, and every
    Chromium version since 136 refuses ``--remote-debugging-port`` on the user's
    own default profile.

Two dependency-free routes are used instead:

1. ``cookies_from_firefox()`` -- Firefox stores cookies in a plain SQLite file,
   so a returning Firefox user is signed in with no window and no click at all.
   Read through Python's own ``sqlite3``; nothing is installed.

2. ``launch_controllable_browser()`` + ``read_devtools_cookies()`` -- the Edge
   (or Chrome) that ships with Windows is started in a profile this app owns,
   pointed at music.youtube.com. The user signs in there exactly as they would
   anywhere else, and the session is read over the DevTools protocol, which the
   browser itself decrypts. No extension, no pasting, nothing to load.

Everything here is standard library only: ``sqlite3``, ``socket``, ``ssl``,
``subprocess`` and a small RFC 6455 client (``_WebSocket``).

Nothing in this module ever logs a cookie name or value.
"""

import base64
import json
import logging
import os
import secrets
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request
from urllib.parse import urlsplit

logger = logging.getLogger("ytmusic-backend")

# Only cookies for these hosts are ever looked at; a browser's cookie store is
# not ours to rummage through, and nothing outside the two YouTube Music needs
# is a session for this app.
_COOKIE_DOMAINS = ("youtube.com", "google.com")

# How long a launch may take to answer on its DevTools port before the attempt
# is called failed. Generous: a cold Edge start on a slow disk is not quick.
_DEVTOOLS_START_TIMEOUT = 20.0

# Chromium browsers this app knows how to drive, most preferred first. Edge is
# first because every Windows 10/11 machine has it.
_BROWSER_CANDIDATES = (
    ("Microsoft Edge", "msedge.exe",
     (r"Microsoft\Edge\Application",)),
    ("Google Chrome", "chrome.exe",
     (r"Google\Chrome\Application",)),
)


class BrowserLaunchError(Exception):
    """Raised when no controllable browser is installed or it will not start."""


# --------------------------------------------------------------- WebSocket

class _WebSocketError(Exception):
    """The DevTools WebSocket refused, dropped or timed out."""


class _WebSocket:
    """A minimal RFC 6455 text client: enough for the DevTools protocol.

    Hand-rolled because the shipped runtime carries no WebSocket library, and
    adding one to the interpreter the installer builds is a much larger change
    than the ~120 lines below. Server frames are never masked and CDP replies
    can exceed a single frame, so both the 16/64-bit lengths and continuation
    frames are handled.
    """

    def __init__(self, url, timeout=5.0):
        self._url = url
        self._timeout = timeout
        self._sock = None
        self._buffer = b""

    def connect(self):
        parts = urlsplit(self._url)
        host = parts.hostname
        if not host:
            raise _WebSocketError("the DevTools endpoint gave no host")
        secure = parts.scheme == "wss"
        port = parts.port or (443 if secure else 80)
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query

        sock = socket.create_connection((host, port), timeout=self._timeout)
        if secure:
            sock = ssl.create_default_context().wrap_socket(
                sock, server_hostname=host
            )
        sock.settimeout(self._timeout)

        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            # No Origin header on purpose: Chromium only enforces
            # --remote-allow-origins for callers that announce an origin.
            "\r\n"
        )
        sock.sendall(request.encode("ascii"))

        header = b""
        while b"\r\n\r\n" not in header:
            chunk = sock.recv(4096)
            if not chunk:
                sock.close()
                raise _WebSocketError("the DevTools endpoint closed the handshake")
            header += chunk
        head, _, rest = header.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            sock.close()
            raise _WebSocketError(
                "the DevTools endpoint refused the upgrade ("
                + status.decode("latin-1", "replace") + ")"
            )

        self._sock = sock
        self._buffer = rest
        return self

    def _recv_exact(self, count):
        while len(self._buffer) < count:
            chunk = self._sock.recv(max(4096, count - len(self._buffer)))
            if not chunk:
                raise _WebSocketError("the DevTools endpoint closed the connection")
            self._buffer += chunk
        data, self._buffer = self._buffer[:count], self._buffer[count:]
        return data

    def _recv_frame(self):
        first, second = self._recv_exact(2)
        final = bool(first & 0x80)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = int.from_bytes(self._recv_exact(2), "big")
        elif length == 127:
            length = int.from_bytes(self._recv_exact(8), "big")
        mask = self._recv_exact(4) if masked else None
        payload = self._recv_exact(length) if length else b""
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return final, opcode, payload

    def _recv_message(self):
        message = b""
        while True:
            final, opcode, payload = self._recv_frame()
            if opcode == 0x8:  # close
                raise _WebSocketError("the DevTools endpoint closed the connection")
            if opcode == 0x9:  # ping -> pong
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:  # pong
                continue
            if opcode in (0x0, 0x1, 0x2):  # continuation, text, binary
                message += payload
            if final:
                return message

    def _send_frame(self, opcode, payload):
        mask = secrets.token_bytes(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        header = bytearray([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += length.to_bytes(2, "big")
        else:
            header.append(0x80 | 127)
            header += length.to_bytes(8, "big")
        self._sock.sendall(bytes(header) + mask + masked)

    def call(self, method, params=None, message_id=1, deadline=None):
        """Send one CDP command and return its ``result`` object."""
        self._send_frame(
            0x1,
            json.dumps({"id": message_id, "method": method, "params": params or {}})
            .encode("utf-8"),
        )
        while True:
            if deadline is not None and time.monotonic() > deadline:
                raise _WebSocketError(f"timed out waiting for {method}")
            try:
                raw = self._recv_message()
            except socket.timeout as e:
                raise _WebSocketError(f"timed out waiting for {method}") from e
            try:
                message = json.loads(raw.decode("utf-8", "replace"))
            except json.JSONDecodeError:
                continue
            # Skip events and replies to other commands (there are none, but a
            # CDP endpoint may interleave events on the same socket).
            if message.get("id") != message_id:
                continue
            if message.get("error"):
                raise _WebSocketError(str(message["error"]))
            return message.get("result") or {}

    def close(self):
        try:
            if self._sock is not None:
                self._send_frame(0x8, b"")
        except (OSError, _WebSocketError):
            pass
        try:
            if self._sock is not None:
                self._sock.close()
        except OSError:
            pass
        self._sock = None


# --------------------------------------------------------------- HTTP probe

def _http_json(url, timeout=3.0):
    """GET a small JSON document from the loopback DevTools endpoint."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except Exception as e:  # noqa: BLE001 - any failure just means "not ready"
        raise _WebSocketError(f"{url} did not answer: {e}") from e


def _devtools_port_alive(port):
    try:
        _http_json(f"http://127.0.0.1:{int(port)}/json/version", timeout=1.5)
        return True
    except _WebSocketError:
        return False


def _read_published_port(port_file):
    try:
        with open(port_file, "r", encoding="ascii") as f:
            first = f.readline().strip()
    except OSError:
        return 0
    try:
        return int(first)
    except ValueError:
        return 0


# --------------------------------------------------------------- browser discovery

def _app_paths_key(exe):
    """The registry lookup Windows itself uses for an installed program."""
    try:
        import winreg
    except ImportError:
        return None
    for hive, subkey in (
        (winreg.HKEY_LOCAL_MACHINE,
         rf"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{exe}"),
        (winreg.HKEY_LOCAL_MACHINE,
         rf"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\{exe}"),
        (winreg.HKEY_CURRENT_USER,
         rf"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{exe}"),
    ):
        try:
            with winreg.OpenKey(hive, subkey) as key:
                value, _ = winreg.QueryValueEx(key, None)
            if value and os.path.exists(value):
                return value
        except OSError:
            continue
    return None


def _known_install(exe, subdirs):
    roots = [
        os.environ.get("ProgramFiles(x86)"),
        os.environ.get("ProgramFiles"),
        os.environ.get("LOCALAPPDATA"),
    ]
    for root in roots:
        if not root:
            continue
        for sub in subdirs:
            candidate = os.path.join(root, sub, exe)
            if os.path.exists(candidate):
                return candidate
    return None


def find_controllable_browser():
    """(friendly name, executable path) for the browser sign-in will drive.

    None when the machine has neither Edge nor Chrome, which is the signal to
    fall back to opening the default browser (and the paste-headers path).
    """
    for name, exe, subdirs in _BROWSER_CANDIDATES:
        path = _app_paths_key(exe) or _known_install(exe, subdirs)
        if path:
            return name, path
    return None


def launch_controllable_browser(url, profile_dir):
    """Start Edge/Chrome on *url* in a profile this app owns.

    Returns the DevTools port. The window is left for the user to sign in (and,
    later, to close); nothing is killed here, so a retry simply reuses the same
    window and the same profile.
    """
    found = find_controllable_browser()
    if found is None:
        raise BrowserLaunchError(
            "Neither Microsoft Edge nor Google Chrome is installed."
        )
    name, exe = found

    os.makedirs(profile_dir, exist_ok=True)
    port_file = os.path.join(profile_dir, "DevToolsActivePort")

    # A port file from a browser that has since exited would send us nowhere;
    # the port is only trusted once /json/version answers on it.
    stale = _read_published_port(port_file)
    if stale and not _devtools_port_alive(stale):
        try:
            os.remove(port_file)
        except OSError:
            pass

    args = [
        exe,
        f"--user-data-dir={profile_dir}",
        "--remote-debugging-port=0",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-mode",
        url,
    ]
    logger.info("browser auth: launching %s in its own profile", name)
    try:
        subprocess.Popen(
            args,
            close_fds=True,
            # Detached so the sign-in window is not a child of the sidecar and
            # survives it; stdio is dropped so nothing inherits our handles.
            creationflags=getattr(subprocess, "DETACHED_PROCESS", 0),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as e:
        raise BrowserLaunchError(f"Could not start {name}: {e}") from e

    deadline = time.monotonic() + _DEVTOOLS_START_TIMEOUT
    while time.monotonic() < deadline:
        port = _read_published_port(port_file)
        if port and _devtools_port_alive(port):
            return port
        time.sleep(0.25)
    raise BrowserLaunchError(f"{name} did not open a debugging port in time.")


# --------------------------------------------------------------- CDP cookies

def _cookies_from_cdp(entries):
    """name -> value for the YouTube/Google cookies in a CDP cookie list."""
    jar = {}
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        value = entry.get("value")
        domain = (entry.get("domain") or "").lstrip(".").lower()
        if not name or value is None:
            continue
        if not any(domain == d or domain.endswith("." + d) for d in _COOKIE_DOMAINS):
            continue
        jar[name] = value
    return jar


def read_devtools_cookies(port, deadline):
    """The browser's YouTube/Google cookies, via the DevTools protocol.

    The browser decrypts its own store, so this works where a file read cannot
    (App-Bound Encryption). Empty when there is no signed-in session yet, which
    is the normal state right after the window opens.
    """
    version = _http_json(f"http://127.0.0.1:{int(port)}/json/version")
    ws_url = version.get("webSocketDebuggerUrl")
    if not ws_url:
        raise _WebSocketError("the DevTools endpoint published no WebSocket URL")

    socket_client = _WebSocket(ws_url, timeout=5.0).connect()
    try:
        try:
            result = socket_client.call(
                "Storage.getCookies", deadline=deadline, message_id=1
            )
        except _WebSocketError:
            # Older/edge builds may not expose Storage; Network is the alias.
            result = socket_client.call(
                "Network.getAllCookies", deadline=deadline, message_id=2
            )
    finally:
        socket_client.close()
    return _cookies_from_cdp(result.get("cookies"))


# --------------------------------------------------------------- Firefox

def _firefox_profile_dirs():
    roots = [
        os.path.join(os.environ.get("APPDATA", ""), "Mozilla", "Firefox", "Profiles"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Mozilla", "Firefox", "Profiles"),
    ]
    for root in roots:
        if root and os.path.isdir(root):
            for entry in sorted(os.listdir(root)):
                path = os.path.join(root, entry)
                if os.path.isfile(os.path.join(path, "cookies.sqlite")):
                    yield path


def _read_firefox_cookies(profile_dir):
    """Copy the cookie DB (plus its WAL) aside, then read that copy.

    Firefox keeps cookies.sqlite open, and recent writes live in the -wal file,
    so the copy has to take all three parts or a fresh sign-in is invisible.
    """
    name = os.path.basename(profile_dir) or "firefox"
    temp_dir = tempfile.mkdtemp(prefix=f"sonore-{name}-")
    try:
        for suffix in ("", "-wal", "-shm"):
            source = os.path.join(profile_dir, "cookies.sqlite" + suffix)
            if os.path.exists(source):
                shutil.copy2(source, os.path.join(temp_dir, "cookies.sqlite" + suffix))
        import sqlite3

        connection = sqlite3.connect(os.path.join(temp_dir, "cookies.sqlite"))
        try:
            rows = connection.execute(
                "SELECT name, value, host FROM moz_cookies"
            ).fetchall()
        finally:
            connection.close()
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)

    jar = {}
    for name, value, host in rows:
        if not name or not value:
            continue
        host = (host or "").lstrip(".").lower()
        if any(host == d or host.endswith("." + d) for d in _COOKIE_DOMAINS):
            jar[name] = value
    return jar


def cookies_from_firefox():
    """The user's existing Firefox session, or None when there is not one.

    Zero clicks and no window: a Firefox user who is already signed in to
    YouTube Music is signed in here too.

    Several profiles are normal (a release build plus a Developer Edition, for
    instance), and an anonymous jar from one must not shadow the session in
    another — so a profile carrying ``SID`` wins over one that merely has
    YouTube cookies, and the first profile is only a last resort.
    """
    fallback = None
    for profile_dir in _firefox_profile_dirs():
        try:
            jar = _read_firefox_cookies(profile_dir)
        except Exception as e:  # noqa: BLE001 - a locked/corrupt DB is not fatal
            logger.warning("browser auth: could not read a Firefox profile (%s)", e)
            continue
        if not jar:
            continue
        if "SID" in jar:
            logger.info("browser auth: read %d cookies from a signed-in Firefox", len(jar))
            return jar
        if fallback is None:
            fallback = jar
    if fallback is not None:
        logger.info("browser auth: read %d cookies from Firefox, but no session", len(fallback))
    return fallback


# --------------------------------------------------------------- profile housekeeping

def browser_profile_dir():
    """The profile this app owns for the sign-in window.

    Beside the app's other per-install state, not inside the install folder, so
    it is per-user and survives an upgrade. Sign-out removes it.
    """
    sonore = os.path.join(
        os.environ.get(
            "LOCALAPPDATA",
            os.path.join(os.path.expanduser("~"), "AppData", "Local"),
        ),
        "Sonore",
    )
    return os.path.join(sonore, "sign-in-browser")


def remove_browser_profile():
    """Forget the sign-in browser's own session. Best-effort: a browser still
    running against the profile keeps its files locked, and that is fine."""
    path = browser_profile_dir()
    if os.path.isdir(path):
        shutil.rmtree(path, ignore_errors=True)
