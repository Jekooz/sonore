/**
 * Sonore Helper — popup (the hand-off trigger).
 *
 * This file is the piece that was missing: the service worker can only send
 * cookies when something asks it to, and the toolbar popup is that trigger. It
 * reads the pairing file's port + one-time token in the worker, so this page
 * never handles cookies or tokens itself — it only asks and reports.
 *
 * All text is written with textContent. The backend's `detail` string is
 * server-supplied, and Chrome's extension docs warn specifically against
 * innerHTML for values that arrive over the wire.
 */

const statusEl = document.getElementById("status");
const sendButton = document.getElementById("send");
const tokenInput = document.getElementById("apiToken");

function setStatus(text, tone) {
    statusEl.textContent = text;
    if (tone) {
        statusEl.dataset.tone = tone;
    } else {
        delete statusEl.dataset.tone;
    }
}

/** Map a worker result onto something the user can act on. */
function describe(result) {
    if (!result) {
        return ["Ready. Press Connect while the app is waiting for sign-in.", null];
    }
    if (result.ok) {
        return ["Done. Your session is now in the app.", "ok"];
    }
    if (result.status === 409) {
        return ["The app is not waiting for sign-in. Start sign-in from the app, then press this again.", "warn"];
    }
    if (result.status === 401) {
        // The sidecar distinguishes a rejected pairing token from a missing or
        // wrong API token in `detail`; both are its own user-facing wording.
        return [result.detail || "Sign-in was rejected. Start sign-in again from the app.", "warn"];
    }
    if (result.status === 422) {
        return [result.detail || "Not signed in to music.youtube.com in this browser.", "warn"];
    }
    if (result.status === 0) {
        return [result.detail || "Could not reach the app.", "warn"];
    }
    return [result.detail || `The app refused the hand-off (HTTP ${result.status}).`, "warn"];
}

document.addEventListener("DOMContentLoaded", () => {
    // The token is the only thing this extension stores, and only so it does
    // not have to be pasted before every hand-off. Cookies are never stored.
    chrome.storage.local.get(["apiToken", "lastResult"], ({ apiToken, lastResult }) => {
        if (typeof apiToken === "string") tokenInput.value = apiToken;

        // Ignore a stale success from an earlier session — it is not this
        // attempt's outcome.
        const previous = lastResult && lastResult.ok ? null : lastResult;
        const [text, tone] = describe(previous);
        setStatus(text, tone);
    });
});

tokenInput.addEventListener("change", () => {
    chrome.storage.local.set({ apiToken: tokenInput.value.trim() });
});

sendButton.addEventListener("click", () => {
    const apiToken = tokenInput.value.trim();
    if (!apiToken) {
        setStatus(
            "Paste the API token from the app (Settings → Account) first.",
            "warn",
        );
        tokenInput.focus();
        return;
    }
    chrome.storage.local.set({ apiToken });

    sendButton.disabled = true;
    setStatus("Connecting to Sonore…", null);

    chrome.runtime.sendMessage({ type: "sendCookies", apiToken }, (result) => {
        sendButton.disabled = false;

        if (chrome.runtime.lastError) {
            setStatus(chrome.runtime.lastError.message || "The helper is not responding.", "warn");
            return;
        }

        const [text, tone] = describe(result);
        setStatus(text, tone);
    });
});
