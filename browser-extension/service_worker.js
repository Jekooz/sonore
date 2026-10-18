/**
 * Sonore Helper — MV3 service worker.
 *
 * Reads the YouTube Music session with chrome.cookies.getAll (which includes
 * HttpOnly cookies like __Secure-3PAPISID) together with the request headers
 * ytmusicapi's browser auth needs (the browser's own user-agent and language),
 * and POSTs both to the local sidecar's loopback-only /auth/handoff endpoint.
 *
 * Cookies are queried by URL rather than by domain: getAll({url}) returns
 * exactly the cookies that would be sent to music.youtube.com, which includes
 * the parent-domain .youtube.com cookies (SID, SAPISID, __Secure-3PAPISID, ...)
 * while the manifest only needs a host permission for music.youtube.com — not
 * the whole youtube.com domain.
 *
 * Pairing: the app writes port + one-time token into the extension folder
 * (sidecar.json) when sign-in starts; the worker reads it, sends once, and
 * reports the result through chrome.storage so the popup can display it.
 *
 * Lockdown: the sidecar also requires the per-install API token (Settings ->
 * Account in the app) on every hand-off. The popup passes it in the message;
 * the worker sends it as X-Sonore-Token. The pairing token alone is not enough.
 */

const CONFIG_URL = chrome.runtime.getURL("sidecar.json");
const MUSIC_ORIGIN = "https://music.youtube.com";

async function loadConfig() {
    // no-store: the app rewrites sidecar.json for EVERY sign-in attempt, so a
    // cached copy would hand back a port/token that has already been rotated
    // away — the hand-off would then be rejected as an invalid token.
    const cfg = await (await fetch(CONFIG_URL, { cache: "no-store" })).json();
    if (!cfg || typeof cfg.port !== "number" || !cfg.token) {
        throw new Error("sidecar.json missing or incomplete — start sign-in from the app first.");
    }
    return cfg;
}

/** The API token from the popup, or from storage if the message omitted it. */
async function resolveApiToken(fromMessage) {
    if (typeof fromMessage === "string" && fromMessage.trim()) {
        return fromMessage.trim();
    }
    const { apiToken } = await chrome.storage.local.get("apiToken");
    return typeof apiToken === "string" ? apiToken.trim() : "";
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

async function sendSessionToApp(apiToken) {
    if (!apiToken) {
        return {
            ok: false,
            status: 401,
            detail: "Paste the API token from the app (Settings → Account) first.",
        };
    }

    const cfg = await loadConfig();
    const cookies = await collectCookies();

    const resp = await fetch(`http://127.0.0.1:${cfg.port}/auth/handoff`, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "X-Ytm-Token": cfg.token,
            "X-Sonore-Token": apiToken,
        },
        body: JSON.stringify({ cookies, headers: collectHeaders() }),
    });

    const detail = await resp.json().catch(() => ({}));
    return { ok: resp.ok, status: resp.status, detail: detail.detail || null };
}

// Message entry point: the popup triggers the hand-off.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg?.type !== "sendCookies") return false;

    resolveApiToken(msg.apiToken)
        .then((apiToken) => sendSessionToApp(apiToken))
        .then((result) => {
            chrome.storage.local.set({ lastResult: result });
            sendResponse(result);
        })
        .catch((err) => {
            const result = { ok: false, status: 0, detail: String(err?.message || err) };
            chrome.storage.local.set({ lastResult: result });
            sendResponse(result);
        });

    return true; // keep the message channel open for the async response
});
