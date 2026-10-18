/**
 * Sonore Helper — MV3 service worker.
 *
 * Hands the YouTube Music session from the user's own browser to the local
 * Sonore app automatically. There is no token to paste and nothing to press:
 *
 *  1. When sign-in starts, the app writes {port, token} into this folder
 *     (sidecar.json) and opens music.youtube.com in the default browser.
 *  2. This worker is woken when the user lands on music.youtube.com and when
 *     the session cookies change. It reads that file, fetches the app's
 *     per-install API token itself, and POSTs the jar + request headers to the
 *     loopback /auth/handoff endpoint.
 *  3. While an attempt is open but the user has not signed in yet, it polls
 *     every 30 s (one alarm at a time) so a sign-in that finishes without a
 *     fresh navigation is still picked up.
 *
 * It only ever sends a jar that actually carries a session: the sidecar
 * requires SID, SAPISID and __Secure-3PAPISID together and treats anything less
 * as a failed attempt, so an anonymous jar (YSC, VISITOR_INFO1_LIVE, …) is held
 * back rather than sent early.
 *
 * Cookies are queried by URL rather than by domain: getAll({url}) returns
 * exactly the cookies that would be sent to music.youtube.com, which includes
 * the parent-domain .youtube.com cookies (SID, SAPISID, __Secure-3PAPISID, ...)
 * while the manifest only needs a host permission for music.youtube.com — not
 * the whole youtube.com domain.
 *
 * Lockdown: the sidecar also requires the per-install API token (X-Sonore-Token)
 * on every hand-off. The worker fetches it from /auth/install-token, which
 * admits extension origins, so the user never has to copy it from Settings.
 */

const CONFIG_URL = chrome.runtime.getURL("sidecar.json");
const MUSIC_ORIGIN = "https://music.youtube.com";
const API_ORIGIN = "http://127.0.0.1";
const RETRY_ALARM = "sonore-retry";
// Chrome clamps alarm delays to 30 s; this is that floor.
const RETRY_DELAY_MINUTES = 0.5;

// The exact set the sidecar demands before it will treat a jar as a signed-in
// session (services/ytmusic_client.py: REQUIRED_COOKIES). All three, or the
// hand-off is premature and would fail the pending attempt.
const SESSION_COOKIES = ["SID", "SAPISID", "__Secure-3PAPISID"];

// One hand-off at a time: the pairing token is single-use, so a second
// concurrent send would only produce a rejected request.
let inFlight = false;
// The pairing token of an attempt already completed, so later triggers on the
// same still-open attempt do not try again.
let completedToken = null;

async function loadConfig() {
    // no-store: the app rewrites sidecar.json for EVERY sign-in attempt, so a
    // cached copy would hand back a port/token that has already been rotated
    // away — the hand-off would then be rejected as an invalid token.
    const cfg = await (await fetch(CONFIG_URL, { cache: "no-store" })).json();
    if (!cfg || typeof cfg.port !== "number" || !cfg.token || cfg.port <= 0) {
        throw new Error("sidecar.json missing or incomplete — start sign-in from the app first.");
    }
    return cfg;
}

/**
 * The sidecar's per-install API token. The user no longer copies this by hand:
 * /auth/install-token is the one endpoint that hands it out, and it admits
 * extension origins precisely so this worker can bootstrap itself.
 */
async function fetchInstallToken(port) {
    const resp = await fetch(`${API_ORIGIN}:${port}/auth/install-token`, {
        cache: "no-store",
    });
    if (!resp.ok) {
        throw new Error(`The app refused to share its token (HTTP ${resp.status}).`);
    }
    const body = await resp.json().catch(() => null);
    const token = body && body.install_token;
    if (typeof token !== "string" || !token) {
        throw new Error("The app did not return an API token.");
    }
    return token;
}

/** True while the app is actually waiting for a hand-off.
 *
 * An unreachable app is not an error here: it simply is not waiting. Treating
 * it as a failure would fill the popup with "Could not reach the app" every
 * time a cookie changed while Sonore was closed.
 */
async function attemptIsWaiting(port) {
    try {
        const resp = await fetch(`${API_ORIGIN}:${port}/auth/browser/status`, {
            cache: "no-store",
        });
        if (!resp.ok) return false;
        const body = await resp.json().catch(() => null);
        return !!body && body.state === "waiting";
    } catch {
        return false;
    }
}

async function collectCookies() {
    // URL-scoped on purpose: it yields every cookie that would travel to
    // music.youtube.com, parent-domain .youtube.com cookies included, while
    // the manifest keeps a host permission for music.youtube.com only.
    const jar = await chrome.cookies.getAll({ url: `${MUSIC_ORIGIN}/` });

    const cookies = {};
    for (const c of jar) {
        if (c && c.name && c.value) cookies[c.name] = c.value;
    }
    return cookies;
}

function collectHeaders() {
    // Only headers that describe THIS browser. Cookie and authorization are
    // deliberately absent: the sidecar derives them from the validated jar so
    // a hostile payload cannot override the session it proved.
    return {
        "user-agent": navigator.userAgent,
        "accept-language": navigator.language || "en-US",
        "origin": MUSIC_ORIGIN,
        "x-origin": MUSIC_ORIGIN,
    };
}

/** A jar is only worth sending once the signed-in session cookies are present. */
function hasSession(cookies) {
    return SESSION_COOKIES.every((name) => !!cookies[name]);
}

function record(result) {
    return chrome.storage.local
        .set({ lastResult: result })
        .catch(() => undefined)
        .then(() => result);
}

/**
 * Try to complete a pending sign-in on its own. Safe to call from any trigger:
 * it is a no-op unless an attempt is open, has not already been served, and the
 * browser actually holds a session.
 */
async function autoHandoff(trigger) {
    if (inFlight) return { skipped: "busy", trigger };
    inFlight = true;

    try {
        let cfg;
        try {
            cfg = await loadConfig();
        } catch {
            // No attempt is open (the app has not written the pairing file).
            return { skipped: "no-attempt", trigger };
        }

        if (completedToken === cfg.token) {
            return { skipped: "already-sent", trigger };
        }

        if (!(await attemptIsWaiting(cfg.port))) {
            completedToken = null;
            return { skipped: "not-waiting", trigger };
        }

        const cookies = await collectCookies();
        if (!hasSession(cookies)) {
            // Mid sign-in. Keep an eye on it, but do not send: an anonymous jar
            // is rejected and would fail the attempt the user is completing.
            await scheduleRetry();
            return record({
                ok: false,
                status: 0,
                detail: "Waiting for you to finish signing in…",
                pending: true,
                trigger,
            });
        }

        const apiToken = await fetchInstallToken(cfg.port);
        const resp = await fetch(`${API_ORIGIN}:${cfg.port}/auth/handoff`, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Ytm-Token": cfg.token,
                "X-Sonore-Token": apiToken,
            },
            body: JSON.stringify({ cookies, headers: collectHeaders() }),
        });

        const detail = await resp.json().catch(() => ({}));
        const result = {
            ok: resp.ok,
            status: resp.status,
            detail: detail.detail || null,
            trigger,
        };
        if (resp.ok) {
            completedToken = cfg.token;
        } else if (resp.status === 409 || resp.status === 401) {
            // The attempt ended, or this token was already spent elsewhere.
            // Nothing more to do until the app starts a new sign-in.
            completedToken = cfg.token;
        }
        return record(result);
    } catch (err) {
        return record({
            ok: false,
            status: 0,
            detail: String((err && err.message) || err),
            trigger,
        });
    } finally {
        inFlight = false;
    }
}

/** Re-check shortly, while an attempt is still open (the timer stops with it). */
async function scheduleRetry() {
    try {
        await chrome.alarms.create(RETRY_ALARM, {
            delayInMinutes: RETRY_DELAY_MINUTES,
        });
    } catch {
        // Alarms are a convenience; the navigation/cookie triggers still work.
    }
}

// --- wake-up triggers ------------------------------------------------------
// MV3 wakes this worker for the events it listens to, so every listener is
// registered synchronously, at the top level.

// The user landed on (or was redirected back to) music.youtube.com.
chrome.webNavigation.onCompleted.addListener(
    () => autoHandoff("navigation"),
    { url: [{ urlPrefix: MUSIC_ORIGIN }] },
);

// A session cookie appeared or changed — this is what fires the instant the
// user finishes signing in, even without a full page navigation.
chrome.cookies.onChanged.addListener((change) => {
    const domain = (change && change.cookie && change.cookie.domain) || "";
    if (/(^|\.)(youtube\.com|google\.com)$/.test(domain)) {
        autoHandoff("cookie");
    }
});

// The bounded retry loop while a sign-in is still pending.
chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm && alarm.name === RETRY_ALARM) autoHandoff("retry");
});

// The popup's manual fallback, and the popup opening on its own.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg?.type !== "autoHandoff") return false;
    autoHandoff(msg.trigger || "popup").then(sendResponse);
    return true; // keep the message channel open for the async response
});
