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
        return ["The pairing token was rejected. Start sign-in again from the app.", "warn"];
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
    chrome.storage.local.get("lastResult", ({ lastResult }) => {
        // Ignore a stale success from an earlier session — it is not this
        // attempt's outcome.
        const previous = lastResult && lastResult.ok ? null : lastResult;
        const [text, tone] = describe(previous);
        setStatus(text, tone);
    });
});

sendButton.addEventListener("click", () => {
    sendButton.disabled = true;
    setStatus("Connecting to Sonore…", null);

    chrome.runtime.sendMessage({ type: "sendCookies" }, (result) => {
        sendButton.disabled = false;

        if (chrome.runtime.lastError) {
            setStatus(chrome.runtime.lastError.message || "The helper is not responding.", "warn");
            return;
        }

        const [text, tone] = describe(result);
        setStatus(text, tone);
    });
});
