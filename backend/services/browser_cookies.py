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

2. ``launch_controllable_browser()`` + ``read_devtools_cookies()`` -- the
   browser the user set as default in Windows (Comet, Brave, Chrome, Edge, ...)
   is started in a profile this app owns, pointed at music.youtube.com. The user
   signs in there exactly as they would anywhere else, and the session is read
   over the DevTools protocol, which the browser itself decrypts. No extension,
   no pasting, nothing to load. A default that cannot be driven -- Firefox, or a
   build that refuses the debugging port -- falls back to Edge or Chrome, which
   every Windows machine has.

Everything here is standard library only: ``sqlite3``, ``socket``, ``ssl``,
``subprocess`` and a small RFC 6455 client (``_WebSocket``).

Nothing in this module ever logs a cookie name or value.
"""

import base64
import json
import logging
import os
import re
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
# moves on to the next browser, and finally fails. Generous: a cold start on a
# slow disk is not quick, and this happens before the profile has even loaded.
_DEVTOOLS_START_TIMEOUT = 15.0

# The browsers that are looked for when the user's own default cannot be driven,
# in preference order. Both are Chromium builds, so both are drivable, and every
# Windows machine has at least one of them.
_BROWSER_CANDIDATES = (
    ("Microsoft Edge", "msedge.exe",
     (r"Microsoft\Edge\Application",)),
    ("Google Chrome", "chrome.exe",
     (r"Google\Chrome\Application",)),
)

# Chromium browsers put their own files in a folder named after the version they
# are built from. That is a property of the install rather than of any one
# vendor, so it is what decides whether a browser nobody has heard of can still
# be driven over the DevTools protocol.
_CHROMIUM_VERSION_DIR = re.compile(r"^\d+\.\d+\.\d+(\.\d+)?$")

# Chromium browsers, by executable name. The structure above catches the rest;
# this only saves a directory listing for the common ones.
_CHROMIUM_STEMS = (
    "chrome", "msedge", "brave", "comet", "opera", "launcher", "vivaldi",
    "chromium", "thorium", "yandex", "iridium", "avastbrowser",
    "avgsecurebrowser", "sidekick",
)

# Firefox and the forks that store cookies the same way: a plain SQLite file,
# which this app reads itself. None of them can be driven over the DevTools
# protocol (that is Chromium's), and none of them needs to be.
_FIREFOX_STEMS = (
    "firefox", "firefox-developer-edition", "firefox-esr", "waterfox",
    "librewolf", "palemoon", "zen", "floorp",
)

# What a browser writes to its own profile once its setup is done, by executable
# stem. A Chromium browser opening a profile it has never seen runs a first-run
# experience, and the profile this app opens is new by construction; --no-first-run
# covers the stock Chromium wizard but not a fork's own. Comet ignores it and
# navigates to its chrome://perplexity-onboarding page instead, so the sign-in
# page never loads and the attempt could only ever time out -- which is the
# "another comet, and it wants setting up" report this table answers.
#
# These are setup booleans, written into a profile this app owns: no credential,
# no cookie, nothing from the user's own profile is read or copied. A browser we
# have not met needs no entry until it is seen doing this.
_READY_FLAGS = {
    "comet": {"perplexity": {"onboarding_completed": True}},
}

# ProgId -> the name people know the browser by. Anything not listed is named
# from its executable instead, so a brand-new browser is not nameless.
_PROGID_NAMES = (
    ("MSEEDGEHTM", "Microsoft Edge"),
    ("CHROMEHTML", "Google Chrome"),
    ("FIREFOXURL", "Mozilla Firefox"),
    ("BRAVEHTML", "Brave"),
    ("COMETHTM", "Comet"),
    ("OPERASTABLE", "Opera"),
    ("OPERHTML", "Opera"),
    ("OPERAHTM", "Opera"),
    ("VIVALDIHTM", "Vivaldi"),
    ("THORIUMHTML", "Thorium"),
    ("YANDEXHTML", "Yandex Browser"),
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


# --------------------------------------------------------------- browser identity

def _exe_from_command(command):
    """The executable a shell open command names, which is what Windows runs."""
    if not command:
        return None
    text = os.path.expandvars(command.strip())
    if text.startswith('"'):
        end = text.find('"', 1)
        candidate = text[1:end] if end > 0 else ""
    else:
        candidate = text.split(" ")[0]
    candidate = candidate.strip()
    if candidate.lower().endswith(".exe") and os.path.exists(candidate):
        return candidate
    return None


def _userchoice_progid():
    """The ProgId Windows would use for a link, from the user's own setting."""
    try:
        import winreg
    except ImportError:
        return ""
    for scheme in ("https", "http"):
        try:
            with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                "Software\\Microsoft\\Windows\\Shell\\Associations"
                "\\UrlAssociations\\" + scheme + "\\UserChoice",
            ) as key:
                value, _ = winreg.QueryValueEx(key, "ProgId")
            if value:
                return value
        except OSError:
            continue
    return ""


def _progid_command(progid):
    """The command a ProgId's open verb runs, i.e. where that browser lives."""
    try:
        import winreg
    except ImportError:
        return ""
    try:
        with winreg.OpenKey(
            winreg.HKEY_CLASSES_ROOT, progid + "\\shell\\open\\command"
        ) as key:
            value, _ = winreg.QueryValueEx(key, None)
        return value or ""
    except OSError:
        return ""


def _friendly_name(progid, exe):
    upper = (progid or "").upper()
    for prefix, name in _PROGID_NAMES:
        if upper.startswith(prefix):
            return name
    stem = os.path.splitext(os.path.basename(exe or ""))[0]
    if not stem:
        return "your browser"
    return stem.replace("-", " ").replace("_", " ").title()


def default_browser():
    """(friendly name, executable) for the user's default HTTPS browser.

    Read from the association the user set in Windows, then resolved through
    that ProgId's own open command -- the same route Windows takes. An
    unfamiliar browser therefore resolves without being listed anywhere here,
    which is the difference between honouring the setting and guessing at it.
    The executable is empty when only the name could be established; None when
    Windows has no opinion at all.
    """
    progid = _userchoice_progid()
    exe = _exe_from_command(_progid_command(progid)) if progid else None
    if not progid and not exe:
        return None
    return _friendly_name(progid, exe), (exe or "")


def is_firefox(name, exe=""):
    """True for Firefox and the forks that keep cookies the same way."""
    if "firefox" in (name or "").lower():
        return True
    stem = os.path.splitext(os.path.basename(exe or ""))[0].lower()
    return stem in _FIREFOX_STEMS


def is_probably_chromium(exe):
    """Whether this browser can be driven over the DevTools protocol.

    Decided by the install, not by a list of vendors: Chromium browsers keep
    their files in a folder named after the version they are built from, so
    Comet, Edge, Chrome and Brave all answer yes and Firefox answers no.
    """
    if not exe:
        return False
    stem = os.path.splitext(os.path.basename(exe))[0].lower()
    if stem in _CHROMIUM_STEMS:
        return True
    try:
        entries = os.listdir(os.path.dirname(exe))
    except OSError:
        return False
    return any(_CHROMIUM_VERSION_DIR.match(entry) for entry in entries)


def controllable_browsers():
    """(name, executable) candidates sign-in can drive, most preferred first.

    The user's own default browser when it is a Chromium, then Edge and Chrome
    -- every Windows machine has one of those two, so an unusual default still
    ends in an automatic sign-in. Firefox never appears here: it is read from
    its own profile instead, which beats a window in a profile nobody uses.
    """
    planned = []
    default = default_browser()
    if default is not None:
        name, exe = default
        if exe and not is_firefox(name, exe) and is_probably_chromium(exe):
            planned.append((name, exe))

    for name, exe_name, subdirs in _BROWSER_CANDIDATES:
        path = _app_paths_key(exe_name) or _known_install(exe_name, subdirs)
        if not path:
            continue
        if any(os.path.normcase(seen) == os.path.normcase(path) for _, seen in planned):
            continue
        planned.append((name, path))
    return planned


def sign_in_plan():
    """How sign-in will get a session: (mode, browser name).

    One decision in one place, so the browser named to the user is always the
    browser that will actually be used:

      "firefox"   read the user's own Firefox profile -- no window at all,
      "devtools"  drive a Chromium in a profile this app owns,
      "shell"     nothing drivable: sign-in cannot finish by itself.
    """
    default = default_browser()
    if default is not None:
        name, exe = default
        if is_firefox(name, exe) and any(_firefox_profile_dirs()):
            return "firefox", name

    candidates = controllable_browsers()
    if candidates:
        return "devtools", candidates[0][0]

    if default is not None:
        return "shell", default[0]
    return "shell", "your browser"


def planned_browser_name():
    """What the UI should name: the browser sign-in will really use."""
    return sign_in_plan()[1]


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


def _profile_for(profile_root, exe):
    """The profile a browser gets: one each, never shared.

    Two browsers writing one Chromium profile directory would corrupt it, and a
    user who changes their default browser should start from a clean profile
    there rather than inherit half of another browser's.
    """
    stem = os.path.splitext(os.path.basename(exe))[0].lower() or "browser"
    slug = "".join(c for c in stem if c.isalnum() or c in "-_")
    return os.path.join(profile_root, slug or "browser")


def _stop_quietly(process):
    """Drop a window we opened but can never read. Best effort, and only ever
    the process this app started: a browser that a failed candidate left open
    would otherwise invite the user to sign in somewhere that cannot finish."""
    try:
        if process.poll() is None:
            process.terminate()
    except OSError:
        pass


def _seed_profile(profile_dir, exe):
    """Mark a brand-new profile as already set up, before it is first opened.

    Browsers record "this profile is set up" in Local State, so that is where
    the flags go. Merged, never replaced: an existing Local State holds the keys
    this profile's cookies are encrypted with, and replacing it would strand a
    session this app had already captured. A browser that will not let us write
    it is still worth launching -- only the vendor wizard depends on this.
    """
    stem = os.path.splitext(os.path.basename(exe))[0].lower()
    flags = {"browser": {"first_run_finished": True}}
    for vendor, values in _READY_FLAGS.get(stem, {}).items():
        flags.setdefault(vendor, {}).update(values)

    path = os.path.join(profile_dir, "Local State")
    state = {}
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                loaded = json.load(handle)
            if isinstance(loaded, dict):
                state = loaded
        except (OSError, json.JSONDecodeError):
            state = {}

    for vendor, values in flags.items():
        section = state.get(vendor)
        if not isinstance(section, dict):
            section = {}
            state[vendor] = section
        section.update(values)

    try:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(state, handle)
    except OSError as e:
        logger.warning("browser auth: could not mark the profile as set up (%s)", e)


def _launch_one(name, exe, url, profile_dir):
    """Start one browser in its own profile; return its DevTools port."""
    os.makedirs(profile_dir, exist_ok=True)
    _seed_profile(profile_dir, exe)
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
        process = subprocess.Popen(
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
        raise BrowserLaunchError(f"could not start it ({e})") from e

    deadline = time.monotonic() + _DEVTOOLS_START_TIMEOUT
    while time.monotonic() < deadline:
        port = _read_published_port(port_file)
        if port and _devtools_port_alive(port):
            return port
        time.sleep(0.25)

    _stop_quietly(process)
    raise BrowserLaunchError("it did not open a debugging port in time")


def launch_controllable_browser(url, profile_root):
    """Start a browser sign-in can read, in a profile this app owns.

    Returns (friendly name, DevTools port). Candidates are tried in preference
    order -- the user's own default browser first -- because a build that will
    not expose a debugging port must not cost the ones that will.

    The window is left open on success for the user to sign in (and to close),
    so a retry reuses the same window and the same profile.
    """
    candidates = controllable_browsers()
    if not candidates:
        raise BrowserLaunchError(
            "Sign-in could not open a browser window it can read: no browser "
            "on this machine can be driven. You can sign in to YouTube Music "
            "in your own browser and paste the request headers in Settings, "
            "under Account."
        )

    attempts = []
    for name, exe in candidates:
        try:
            return name, _launch_one(name, exe, url, _profile_for(profile_root, exe))
        except BrowserLaunchError as e:
            logger.warning("browser auth: %s cannot be driven: %s", name, e)
            attempts.append(f"{name}: {e}")

    raise BrowserLaunchError(
        "Sign-in could not open a browser window ("
        + "; ".join(attempts)
        + "). You can sign in to YouTube Music in your own browser and paste "
        "the request headers in Settings, under Account."
    )


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
        # Debug, not info: this runs on every poll of a Firefox sign-in, and
        # "there are cookies but not a session yet" is the normal state right
        # after the window opens.
        logger.debug("browser auth: read %d cookies from Firefox, but no session", len(fallback))
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
