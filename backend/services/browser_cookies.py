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

2. ``launch_readable_browser()`` + ``read_profile_cookies()`` -- the browser the
   user set as default in Windows (Comet, Brave, Chrome, Edge, ...) is started
   in a profile this app owns, pointed at music.youtube.com. The user signs in
   there exactly as they would anywhere else and closes the window; the session
   is then decrypted out of that profile's own store: its key comes from Local
   State through DPAPI, and its v10 cookies are AES-256-GCM, which Windows' own
   CNG decrypts. No extension, no pasting, nothing to load.

   The window is deliberately NOT driven over the DevTools protocol. Google
   refuses sign-in with "This browser or app may not be secure" in a browser
   that exposes a debugging port -- verified against /v3/signin/rejected -- so a
   driven window can never produce a session. A plain one is what a normal user
   has.

Everything here is standard library only: ``sqlite3``, ``subprocess``, and
``ctypes`` over Windows' own crypt32/bcrypt.

Nothing in this module ever logs a cookie name or value.
"""

import base64
import ctypes
import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
from ctypes import wintypes

logger = logging.getLogger("ytmusic-backend")

# Only cookies for these hosts are ever looked at; a browser's cookie store is
# not ours to rummage through, and nothing outside the two YouTube Music needs
# is a session for this app.
_COOKIE_DOMAINS = ("youtube.com", "google.com")

# How long a launch may take to publish the profile key before the attempt
# moves on to the next browser, and finally fails. Generous: a cold start on a
# slow disk is not quick, and this happens before the profile has even loaded.
_PROFILE_READY_TIMEOUT = 25.0

# The browsers that are looked for when the user's own default cannot be read,
# in preference order. Both are Chromium builds, so both keep a profile this app
# can read, and every Windows machine has at least one of them.
_BROWSER_CANDIDATES = (
    ("Microsoft Edge", "msedge.exe",
     (r"Microsoft\Edge\Application",)),
    ("Google Chrome", "chrome.exe",
     (r"Google\Chrome\Application",)),
)

# Chromium browsers put their own files in a folder named after the version they
# are built from. That is a property of the install rather than of any one
# vendor, so it is what decides whether a browser nobody has heard of still
# keeps a profile this app can read.
_CHROMIUM_VERSION_DIR = re.compile(r"^\d+\.\d+\.\d+(\.\d+)?$")

# Chromium browsers, by executable name. The structure above catches the rest;
# this only saves a directory listing for the common ones.
_CHROMIUM_STEMS = (
    "chrome", "msedge", "brave", "comet", "opera", "launcher", "vivaldi",
    "chromium", "thorium", "yandex", "iridium", "avastbrowser",
    "avgsecurebrowser", "sidekick",
)

# Firefox and the forks that store cookies the same way: a plain SQLite file,
# which this app reads itself. None of them keeps a Chromium profile, and none of
# them needs to.
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
    """Raised when no readable browser is installed or it will not start."""


# --------------------------------------------------------------- browser discovery

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
    """Whether this browser keeps a profile this app can read.

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
    """(name, executable) candidates sign-in can read, most preferred first.

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
      "profile"   open a Chromium in a profile this app owns, then read it,
      "shell"     nothing this app can read: sign-in cannot finish by itself.
    """
    default = default_browser()
    if default is not None:
        name, exe = default
        if is_firefox(name, exe) and any(_firefox_profile_dirs()):
            return "firefox", name

    candidates = controllable_browsers()
    if candidates:
        return "profile", candidates[0][0]

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


def _pid_running(pid):
    """Whether a process with this id is still alive."""
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(0x1000, False, int(pid))  # QUERY_LIMITED
    if not handle:
        return False
    try:
        code = wintypes.DWORD()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
            return False
        return code.value == _STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def _windows_of(pid):
    """Top-level windows owned by a process."""
    user32 = ctypes.windll.user32
    found = []
    prototype = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def each(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == int(pid) and user32.IsWindowVisible(hwnd):
            found.append(hwnd)
        return True

    user32.EnumWindows(prototype(each), 0)
    return found


def close_browser_window(process):
    """Ask the sign-in window to close, so it flushes its cookie store.

    A window message, not a kill: Chromium commits cookies on a timer, so a
    window that is terminated can take the session it just received with it.
    """
    if process is None or process.poll() is not None:
        return
    user32 = ctypes.windll.user32
    for hwnd in _windows_of(process.pid):
        user32.PostMessageW(hwnd, _WM_CLOSE, 0, 0)


def _close_stale_window(profile_dir):
    """Close a sign-in window left over from an earlier attempt.

    Chromium runs one process per profile: launching again against a profile
    that is still open only opens a tab in the existing window and exits, so a
    leftover window would make every later attempt look like an instant
    failure. Recorded by pid when the window was opened.
    """
    path = os.path.join(profile_dir, _PID_FILE)
    try:
        with open(path, encoding="ascii") as handle:
            pid = int(handle.read().strip())
    except (OSError, ValueError):
        return
    if _pid_running(pid):
        user32 = ctypes.windll.user32
        for hwnd in _windows_of(pid):
            user32.PostMessageW(hwnd, _WM_CLOSE, 0, 0)
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if read_profile_cookies(profile_dir) is not None:
                break
            time.sleep(0.25)
    try:
        os.remove(path)
    except OSError:
        pass


def _launch_one(name, exe, url, profile_dir):
    """Start one browser in its own profile; return its process."""
    os.makedirs(profile_dir, exist_ok=True)
    _seed_profile(profile_dir, exe)
    # Debris left by the version that drove the browser over DevTools. Nothing
    # reads it now, and a stale port file is exactly what a later reader would
    # trust, so it does not outlive the code that wrote it.
    try:
        os.remove(os.path.join(profile_dir, "DevToolsActivePort"))
    except OSError:
        pass

    args = [
        exe,
        f"--user-data-dir={profile_dir}",
        # Deliberately no --remote-debugging-port: Google refuses sign-in with
        # "This browser or app may not be secure" in a browser that exposes one
        # (it redirects straight to /v3/signin/rejected), so a driven window can
        # never produce a session. This is a plain browser window.
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

    try:
        with open(os.path.join(profile_dir, _PID_FILE), "w", encoding="ascii") as handle:
            handle.write(str(process.pid))
    except OSError:
        pass

    # Whether the window can be read afterwards is structural, so it is settled
    # now: a profile whose key is bound to the browser process (App-Bound
    # Encryption) can be signed in but never read, and must not cost the user a
    # sign-in they cannot finish.
    deadline = time.monotonic() + _PROFILE_READY_TIMEOUT
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise BrowserLaunchError("it closed as soon as it started")
        if profile_is_readable(profile_dir):
            return process
        if _os_crypt(profile_dir).get("app_bound_encrypted_key"):
            _stop_quietly(process)
            raise BrowserLaunchError(
                "it locks its cookies to itself, so a session signed in there "
                "could not be read afterwards"
            )
        time.sleep(0.25)

    _stop_quietly(process)
    raise BrowserLaunchError("it did not finish starting in time")


def launch_readable_browser(url, profile_root):
    """Start a browser sign-in can read, in a profile this app owns.

    Returns (friendly name, profile directory, process). Candidates are tried in
    preference order -- the user's own default browser first -- so a browser
    nobody has met cannot cost the ones that can finish.

    The window is left open for the user to sign in. They close it when they are
    done, which is also what flushes the cookie store this app reads.
    """
    candidates = controllable_browsers()
    if not candidates:
        raise BrowserLaunchError(
            "Sign-in could not open a browser window it can read: no Chromium "
            "browser was found. You can sign in to YouTube Music in your own "
            "browser and paste the request headers in Settings, under Account."
        )

    attempts = []
    for name, exe in candidates:
        profile_dir = _profile_for(profile_root, exe)
        try:
            _close_stale_window(profile_dir)
            return name, profile_dir, _launch_one(name, exe, url, profile_dir)
        except BrowserLaunchError as e:
            logger.warning("browser auth: %s cannot be read: %s", name, e)
            attempts.append(f"{name}: {e}")

    raise BrowserLaunchError(
        "Sign-in could not open a browser window it can read ("
        + "; ".join(attempts)
        + "). You can sign in to YouTube Music in your own browser and paste "
        "the request headers in Settings, under Account."
    )


# ------------------------------------------------------------ profile cookies

_V10 = b"v10"
_GCM_NONCE = 12
_GCM_TAG = 16
_STILL_ACTIVE = 259
_WM_CLOSE = 0x0010
_PID_FILE = "signin.pid"
_STATE_FILE = "Local State"
_COOKIE_DB = ("Default", "Network", "Cookies")


def _os_crypt(profile_dir):
    """The os_crypt section of a profile's Local State, or {}."""
    path = os.path.join(profile_dir, _STATE_FILE)
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            state = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    crypt = state.get("os_crypt") if isinstance(state, dict) else None
    return crypt if isinstance(crypt, dict) else {}


def profile_is_readable(profile_dir):
    """Whether this profile's cookies can be read without the browser.

    App-Bound Encryption binds the key to the browser's own process, so a
    profile carrying one can be signed in but never read afterwards. A profile
    this app creates has only the DPAPI-protected key, which is what makes this
    route possible.
    """
    crypt = _os_crypt(profile_dir)
    return bool(crypt.get("encrypted_key")) and not crypt.get("app_bound_encrypted_key")


class _DataBlob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD),
                ("pbData", ctypes.POINTER(ctypes.c_char))]


def _dpapi_unprotect(blob):
    """Unwrap a DPAPI blob as the Windows user who is running this app."""
    out = _DataBlob()
    source = _DataBlob(len(blob), ctypes.cast(
        ctypes.create_string_buffer(blob, len(blob)),
        ctypes.POINTER(ctypes.c_char)))
    if not ctypes.windll.crypt32.CryptUnprotectData(
            ctypes.byref(source), None, None, None, None, 0, ctypes.byref(out)):
        raise OSError("the profile key could not be unwrapped")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out.pbData)


class _AuthInfo(ctypes.Structure):
    """BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO, from Windows CNG."""

    _fields_ = [
        ("cbSize", wintypes.ULONG),
        ("dwInfoVersion", wintypes.ULONG),
        ("pbNonce", ctypes.POINTER(ctypes.c_ubyte)),
        ("cbNonce", wintypes.ULONG),
        ("pbAuthData", ctypes.POINTER(ctypes.c_ubyte)),
        ("cbAuthData", wintypes.ULONG),
        ("pbTag", ctypes.POINTER(ctypes.c_ubyte)),
        ("cbTag", wintypes.ULONG),
        ("pbMacContext", ctypes.POINTER(ctypes.c_ubyte)),
        ("cbMacContext", wintypes.ULONG),
        ("cbAAD", wintypes.ULONG),
        ("cbData", ctypes.c_ulonglong),
        ("dwFlags", wintypes.ULONG),
    ]


def _aes_gcm_decrypt(key, nonce, ciphertext, tag):
    """AES-256-GCM through Windows' own CNG, so nothing has to be installed.

    The tag is authenticated by the cipher: a wrong key or a tampered blob
    raises instead of returning plausible-looking bytes.
    """
    bcrypt = ctypes.windll.bcrypt
    handle = ctypes.c_void_p()
    if bcrypt.BCryptOpenAlgorithmProvider(ctypes.byref(handle), "AES", None, 0):
        raise OSError("AES is unavailable")
    try:
        mode = ctypes.c_wchar_p("ChainingModeGCM")
        if bcrypt.BCryptSetProperty(handle, "ChainingMode", mode,
                                    ctypes.sizeof(mode), 0):
            raise OSError("GCM is unavailable")
        object_length = wintypes.ULONG()
        written = wintypes.ULONG()
        if bcrypt.BCryptGetProperty(handle, "ObjectLength",
                                    ctypes.byref(object_length), 4,
                                    ctypes.byref(written), 0):
            raise OSError("the key could not be sized")
        key_handle = ctypes.c_void_p()
        key_object = ctypes.create_string_buffer(object_length.value)
        key_bytes = ctypes.create_string_buffer(key, len(key))
        if bcrypt.BCryptGenerateSymmetricKey(
                handle, ctypes.byref(key_handle), key_object,
                object_length.value, key_bytes, len(key), 0):
            raise OSError("the key could not be imported")
        try:
            info = _AuthInfo()
            info.cbSize = ctypes.sizeof(info)
            info.dwInfoVersion = 1
            nonce_buffer = (ctypes.c_ubyte * len(nonce)).from_buffer_copy(nonce)
            tag_buffer = (ctypes.c_ubyte * len(tag)).from_buffer_copy(tag)
            data_buffer = (ctypes.c_ubyte * len(ciphertext)).from_buffer_copy(ciphertext)
            info.pbNonce, info.cbNonce = nonce_buffer, len(nonce)
            info.pbTag, info.cbTag = tag_buffer, len(tag)

            out = ctypes.create_string_buffer(len(ciphertext))
            status = bcrypt.BCryptDecrypt(
                key_handle, data_buffer, len(ciphertext), ctypes.byref(info),
                None, 0, out, len(ciphertext), ctypes.byref(written), 0)
            if status:
                raise OSError(
                    f"the cookie could not be decrypted (0x{status & 0xFFFFFFFF:08X})"
                )
            return out.raw[: written.value]
        finally:
            bcrypt.BCryptDestroyKey(key_handle)
    finally:
        bcrypt.BCryptCloseAlgorithmProvider(handle, 0)


def _profile_key(profile_dir):
    """The 32-byte AES key this profile encrypts cookies with, or None."""
    crypt = _os_crypt(profile_dir)
    if crypt.get("app_bound_encrypted_key"):
        # App-Bound Encryption: the real key is only unwrappable by the browser
        # itself, so the DPAPI key beside it is not the one the cookies use.
        return None
    encrypted = crypt.get("encrypted_key")
    if not encrypted:
        return None
    try:
        blob = base64.b64decode(encrypted)
    except (TypeError, ValueError):
        return None
    if not blob.startswith(b"DPAPI"):
        return None
    try:
        return _dpapi_unprotect(blob[5:])
    except OSError as e:
        logger.debug("browser auth: the profile key could not be read (%s)", e)
        return None


def read_profile_cookies(profile_dir):
    """The YouTube/Google cookies in a profile this app owns.

    None means the store could not be read (a browser still holds it); {} means
    it was read and holds no session. That difference decides whether a closed
    window was a failure or whether another window still has to be closed.
    """
    if not profile_dir:
        return None
    database = os.path.join(profile_dir, *_COOKIE_DB)
    if not os.path.isfile(database):
        return {} if os.path.isdir(profile_dir) else None
    key = _profile_key(profile_dir)
    if key is None:
        return None

    uri = "file:" + database.replace(os.sep, "/") + "?mode=ro"
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=2)
    except sqlite3.Error:
        return None
    try:
        rows = connection.execute(
            "SELECT host_key, name, value, encrypted_value FROM cookies"
        ).fetchall()
    except sqlite3.Error:
        return None
    finally:
        connection.close()

    jar = {}
    for host_key, name, value, encrypted in rows:
        if not name:
            continue
        host = (host_key or "").lstrip(".").lower()
        if not any(host == d or host.endswith("." + d) for d in _COOKIE_DOMAINS):
            continue
        if value:
            jar[name] = value
            continue
        if not encrypted or not encrypted.startswith(_V10):
            continue
        try:
            plain = _aes_gcm_decrypt(
                key,
                encrypted[3:3 + _GCM_NONCE],
                encrypted[3 + _GCM_NONCE:-_GCM_TAG],
                encrypted[-_GCM_TAG:],
            )
        except OSError:
            continue
        # Chromium prefixes the value with sha256(host_key). A mismatch means
        # the blob was not written for this row, so it is not this cookie.
        if plain[:32] != hashlib.sha256((host_key or "").encode()).digest():
            continue
        jar[name] = plain[32:].decode("utf-8", "replace")
    return jar


def stored_sign_in_cookies():
    """A session already in the profile sign-in would open, without opening it.

    This is the "already signed in" path: no window, no process, nothing to
    click. Empty when there is no such profile or no session in it.
    """
    if sign_in_plan()[0] != "profile":
        return {}
    candidates = controllable_browsers()
    if not candidates:
        return {}
    _, exe = candidates[0]
    return read_profile_cookies(_profile_for(browser_profile_dir(), exe)) or {}


def cookies_from_disk():
    """Any session already on this machine, without opening anything."""
    return cookies_from_firefox() or stored_sign_in_cookies()


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
