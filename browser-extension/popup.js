/**
 * Sonore Helper — popup (status + manual fallback).
 *
 * Sign-in is automatic: the service worker watches for the user landing on
 * music.youtube.com and hands the session over by itself. This popup exists so
 * the user can *see* what happened, and press "Send my session now" if the
 * automatic hand-off did not complete for some reason. There is no token to
 * paste — the worker fetches it.
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
        return ["Ready. Sign in to music.youtube.com and this finishes on its own.", null];
    }
    if (result.skipped === "no-attempt" || result.skipped === "not-waiting") {
        return ["No sign-in is waiting. Start sign-in from the app first — then it completes on its own.", "warn"];
    }
    if (result.skipped === "already-sent") {
        return ["Done. Your session is now in the app.", "ok"];
    }
    if (result.skipped === "busy") {
        return ["Still working on the last attempt. Try again in a moment.", null];
    }
    if (result.ok) {
        return ["Done. Your session is now in the app.", "ok"];
    }
    if (result.pending) {
        return ["Waiting for you to finish signing in to YouTube Music…", null];
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

/** Ask the worker to complete a pending sign-in, and show the outcome. */
function requestHandoff(trigger) {
    sendButton.disabled = true;
    setStatus("Connecting to Sonore…", null);

    chrome.runtime.sendMessage({ type: "autoHandoff", trigger }, (result) => {
        sendButton.disabled = false;

        if (chrome.runtime.lastError) {
            setStatus(chrome.runtime.lastError.message || "The helper is not responding.", "warn");
            return;
        }

        const [text, tone] = describe(result);
        setStatus(text, tone);
    });
}

document.addEventListener("DOMContentLoaded", () => {
    // Show the last automatic outcome while this attempt is still fresh, then
    // ask the worker to try again (the user may have opened the popup exactly
    // because nothing seemed to happen).
    chrome.storage.local.get(["lastResult"], ({ lastResult }) => {
        const stale = lastResult && lastResult.ok ? null : lastResult;
        const [text, tone] = describe(stale);
        setStatus(text, tone);
        requestHandoff("popup-open");
    });
});

sendButton.addEventListener("click", () => requestHandoff("popup"));
