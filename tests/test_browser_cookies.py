"""
Unit coverage for the dependency-free cookie capture.

Two things here are worth real tests because nothing else exercises them:

* the Chromium profile reader -- a real ``Local State`` with a real DPAPI key
  and a real v10 cookie database, so the encryption format itself is verified
  rather than a mock of it. The values are produced with the browser's half of
  the format (AES-256-GCM through Windows CNG) and read back through the code
  the app ships.
* the Firefox reader -- a real ``moz_cookies`` SQLite file in a tmp profile.
"""

import base64
import ctypes
import hashlib
import json
import os
import sqlite3
import sys
from ctypes import wintypes

import pytest

BACKEND_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "backend"
)
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from services import browser_cookies as bc  # noqa: E402

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


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


# ------------------------------------------------------------ profile cookies
#
# The sign-in window is a plain browser -- no debugging port, because Google
# refuses sign-in in one that has it -- so its session is decrypted out of the
# profile's own store: the key in Local State unwrapped with DPAPI, and v10
# values decrypted with AES-256-GCM through Windows CNG. These build a real
# profile with a real DPAPI key, so the format is what is tested, not a mock.

needs_windows = pytest.mark.skipif(os.name != "nt", reason="Windows crypto")


def _dpapi_protect(data):
    class Blob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD),
                    ("pbData", ctypes.POINTER(ctypes.c_char))]

    source = Blob(len(data), ctypes.cast(
        ctypes.create_string_buffer(data, len(data)),
        ctypes.POINTER(ctypes.c_char)))
    out = Blob()
    if not ctypes.windll.crypt32.CryptProtectData(
            ctypes.byref(source), None, None, None, None, 0, ctypes.byref(out)):
        raise OSError("CryptProtectData failed")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(out.pbData)


def _aes_gcm_encrypt(key, nonce, plaintext):
    """The browser's half of the format, so the reader is tested end to end."""
    bcrypt = ctypes.windll.bcrypt
    handle = ctypes.c_void_p()
    assert bcrypt.BCryptOpenAlgorithmProvider(
        ctypes.byref(handle), "AES", None, 0) == 0
    try:
        mode = ctypes.c_wchar_p("ChainingModeGCM")
        assert bcrypt.BCryptSetProperty(
            handle, "ChainingMode", mode, ctypes.sizeof(mode), 0) == 0
        size = wintypes.ULONG()
        written = wintypes.ULONG()
        assert bcrypt.BCryptGetProperty(
            handle, "ObjectLength", ctypes.byref(size), 4,
            ctypes.byref(written), 0) == 0
        key_handle = ctypes.c_void_p()
        key_object = ctypes.create_string_buffer(size.value)
        key_bytes = ctypes.create_string_buffer(key, len(key))
        assert bcrypt.BCryptGenerateSymmetricKey(
            handle, ctypes.byref(key_handle), key_object, size.value,
            key_bytes, len(key), 0) == 0
        try:
            info = bc._AuthInfo()
            info.cbSize = ctypes.sizeof(info)
            info.dwInfoVersion = 1
            nonce_buffer = (ctypes.c_ubyte * len(nonce)).from_buffer_copy(nonce)
            tag_buffer = (ctypes.c_ubyte * 16)()
            data = (ctypes.c_ubyte * len(plaintext)).from_buffer_copy(plaintext)
            info.pbNonce, info.cbNonce = nonce_buffer, len(nonce)
            info.pbTag, info.cbTag = tag_buffer, 16
            out = ctypes.create_string_buffer(len(plaintext))
            written = wintypes.ULONG()
            assert bcrypt.BCryptEncrypt(
                key_handle, data, len(plaintext), ctypes.byref(info), None, 0,
                out, len(plaintext), ctypes.byref(written), 0) == 0
            return out.raw[:written.value] + bytes(tag_buffer)
        finally:
            bcrypt.BCryptDestroyKey(key_handle)
    finally:
        bcrypt.BCryptCloseAlgorithmProvider(handle, 0)


def _write_profile(root, rows, key=b"k" * 32, app_bound=False):
    """A Chromium-shaped profile: Local State key plus an encrypted cookie DB."""
    network = os.path.join(str(root), "Default", "Network")
    os.makedirs(network, exist_ok=True)
    crypt = {
        "encrypted_key": base64.b64encode(
            b"DPAPI" + _dpapi_protect(key)
        ).decode("ascii")
    }
    if app_bound:
        crypt["app_bound_encrypted_key"] = "AAAA"
    with open(os.path.join(str(root), "Local State"), "w", encoding="utf-8") as f:
        json.dump({"os_crypt": crypt}, f)

    connection = sqlite3.connect(os.path.join(network, "Cookies"))
    connection.execute(
        "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, "
        "encrypted_value BLOB)"
    )
    for host, name, value in rows:
        nonce = os.urandom(12)
        plaintext = hashlib.sha256(host.encode()).digest() + value.encode()
        encrypted = b"v10" + nonce + _aes_gcm_encrypt(key, nonce, plaintext)
        connection.execute(
            "INSERT INTO cookies VALUES (?,?,?,?)", (host, name, "", encrypted)
        )
    connection.commit()
    connection.close()
    return str(root)


@needs_windows
def test_a_profile_key_is_unwrapped_and_its_cookies_decrypted(tmp_path):
    profile = _write_profile(tmp_path, [
        (".google.com", "SID", "session"),
        (".youtube.com", "__Secure-3PAPISID", "apisid"),
    ])

    assert bc.read_profile_cookies(profile) == {
        "SID": "session",
        "__Secure-3PAPISID": "apisid",
    }


@needs_windows
def test_only_youtube_and_google_cookies_are_read(tmp_path):
    profile = _write_profile(tmp_path, [
        (".google.com", "SID", "keep"),
        (".example.com", "csrftoken", "drop"),
        (".google-analytics.com", "_ga", "drop"),
    ])

    assert bc.read_profile_cookies(profile) == {"SID": "keep"}


@needs_windows
def test_a_plaintext_cookie_value_is_taken_as_is(tmp_path):
    profile = _write_profile(tmp_path, [])
    connection = sqlite3.connect(
        os.path.join(profile, "Default", "Network", "Cookies")
    )
    connection.execute(
        "INSERT INTO cookies VALUES (?,?,?,?)", (".youtube.com", "PREF", "f6=400", b"")
    )
    connection.commit()
    connection.close()

    assert bc.read_profile_cookies(profile) == {"PREF": "f6=400"}


@needs_windows
def test_a_cookie_from_another_host_is_not_accepted(tmp_path):
    """The sha256(host_key) prefix is what binds a blob to its own row."""
    profile = _write_profile(tmp_path, [(".google.com", "SID", "session")])
    connection = sqlite3.connect(
        os.path.join(profile, "Default", "Network", "Cookies")
    )
    connection.execute("UPDATE cookies SET host_key='.youtube.com'")
    connection.commit()
    connection.close()

    assert bc.read_profile_cookies(profile) == {}


@needs_windows
def test_a_profile_with_app_bound_encryption_is_not_readable(tmp_path):
    """Its key belongs to the browser process; there is no honest way in."""
    profile = _write_profile(
        tmp_path, [(".google.com", "SID", "session")], app_bound=True
    )

    assert not bc.profile_is_readable(profile)
    assert bc.read_profile_cookies(profile) is None


@needs_windows
def test_a_profile_without_its_key_is_unreadable_rather_than_empty(tmp_path):
    """Unreadable and empty are different answers, and callers rely on it."""
    profile = _write_profile(tmp_path, [(".google.com", "SID", "session")])
    os.remove(os.path.join(profile, "Local State"))

    assert bc.read_profile_cookies(profile) is None


def test_a_profile_with_no_cookie_db_yet_is_empty_not_unreadable(tmp_path):
    profile = tmp_path / "fresh"
    profile.mkdir()

    assert bc.read_profile_cookies(str(profile)) == {}


def test_a_missing_profile_has_nothing_to_read(tmp_path):
    assert bc.read_profile_cookies(str(tmp_path / "nope")) is None


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


def test_a_numbered_version_folder_means_chromium_is_readable(tmp_path):
    """How an unlisted browser (Comet) is known to keep a readable profile."""
    assert bc.is_probably_chromium(_install_with_version_folder(tmp_path))


def test_a_firefox_shaped_install_is_not_readable(tmp_path):
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
    """It is read from its own profile, not opened in one of ours."""
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


def test_the_plan_opens_a_chromium_default_in_a_profile_of_ours(monkeypatch, tmp_path):
    exe = _install_with_version_folder(tmp_path, "comet.exe")
    monkeypatch.setattr(bc, "_firefox_profile_dirs", lambda: iter([]))
    monkeypatch.setattr(bc, "default_browser", lambda: ("Comet", exe))
    monkeypatch.setattr(bc, "_app_paths_key", lambda name: None)
    monkeypatch.setattr(
        bc, "_known_install", lambda exe_name, subdirs: r"C:\Edge\msedge.exe"
    )

    assert bc.sign_in_plan() == ("profile", "Comet")


def test_the_plan_falls_back_to_edge_when_the_default_cannot_be_read(
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

    assert bc.sign_in_plan() == ("profile", "Microsoft Edge")


def test_the_plan_admits_when_nothing_can_be_read(monkeypatch, tmp_path):
    """No readable browser at all: the caller must fail, not open a window."""
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
    """A browser that locks its cookies must not cost one that does not."""
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
            raise bc.BrowserLaunchError("it did not finish starting in time")
        return 4321

    monkeypatch.setattr(bc, "_launch_one", launch_one)

    assert bc.launch_readable_browser(
        "https://music.youtube.com", str(tmp_path)
    ) == ("Microsoft Edge", os.path.join(str(tmp_path), "msedge"), 4321)
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
        bc.launch_readable_browser("https://music.youtube.com", str(tmp_path))

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
