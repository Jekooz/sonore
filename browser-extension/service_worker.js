/**
 * YT Music Client Helper — MV3 service worker.
 *
 * Reads the youtube.com cookie jar with chrome.cookies.getAll (which includes
 * HttpOnly cookies like __Secure-3PAPISID) and POSTs them to the local backend
 * (http://127.0.0.1:<port>/auth/extension). Host permissions in manifest.json
 * cover youtube.com only; the POST target is loopback.
 *
 * Pairing: the app writes port + one-time token into the extension folder
 * (sidecar.json) when sign-in starts; the worker reads it, sends once, and
 * reports the result through chrome.storage so the popup can display it.
 */

const CONFIG_URL = chrome.runtime.getURL("sidecar.json");

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

async function collectCookies() {
    // Entertainment + music domains; google.com is NOT needed: the SAPISID/
    // __Secure-3PAPISID/SID session cookies live on .youtube.com too.
    const jars = await Promise.all([
        chrome.cookies.getAll({ domain: "youtube.com" }),
        chrome.cookies.getAll({ domain: "music.youtube.com" }),
    ]);

    const cookies = {};
    for (const jar of jars) {
        for (const c of jar) {
            if (c && c.name && c.value) cookies[c.name] = c.value;
        }
    }
    return cookies;
}

async function sendCookiesToApp() {
    const cfg = await loadConfig();
    const cookies = await collectCookies();

    const resp = await fetch(`http://127.0.0.1:${cfg.port}/auth/extension`, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "X-Ytm-Token": cfg.token,
        },
        body: JSON.stringify({ cookies }),
    });

    const detail = await resp.json().catch(() => ({}));
    return { ok: resp.ok, status: resp.status, detail: detail.detail || null };
}

// Message entry point: the popup triggers the hand-off.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg?.type !== "sendCookies") return false;

    sendCookiesToApp()
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
