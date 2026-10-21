"""Bridge the host sidecar to the Android emulator.

Why this exists
---------------
The app talks to a local service over plain HTTP. On a device that service
would live on the device itself (127.0.0.1), but during development it runs on
the developer machine and the emulator reaches it through the host alias
10.0.2.2. Two things get in the way there:

1. The sidecar refuses a request whose ``Host`` header is not a loopback name
   (``backend/main.py`` -> ``_non_loopback_rejection``), because that header is
   what stops DNS rebinding from a web page. The emulator's alias is not a
   loopback name, so the sidecar answers 403.
2. The app must reach the sidecar by a *loopback* name, whatever address it
   actually dials.

This bridge is the second half of the story: it listens on a loopback port on
the host, accepts the emulator's request on 10.0.2.2, and forwards it to the
sidecar with the ``Host`` header rewritten to loopback. It is a development
aid only - nothing in the app depends on it.

Usage
-----
    python tool/android_sidecar_bridge.py            # 127.0.0.1:8126 -> 127.0.0.1:8000
    python tool/android_sidecar_bridge.py 8126 8000  # explicit ports

Then run the app against it:

    flutter run -d emulator-5554 --dart-define=YTM_BASE_URL=http://10.0.2.2:8126
"""

import http.client
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_LISTEN_PORT = 8126
DEFAULT_TARGET_PORT = 8000
TARGET_HOST = "127.0.0.1"

# Headers that describe a single hop and must not be copied to the other side.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length",
    "host",
}


class Bridge(BaseHTTPRequestHandler):
    """Forwards every request to the sidecar with a loopback Host header."""

    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _forward(self, method: str) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in HOP_BY_HOP
        }
        # The sidecar only accepts loopback host names, and it *is* the local
        # service the app is calling.
        headers["Host"] = f"{TARGET_HOST}:{self.server.target_port}"

        try:
            conn = http.client.HTTPConnection(
                TARGET_HOST, self.server.target_port, timeout=180
            )
            conn.request(method, self.path, body=body, headers=headers)
            response = conn.getresponse()
            payload = response.read()
        except Exception as exc:  # noqa: BLE001 - the bridge reports it plainly
            self.send_error(502, f"bridge failed: {exc}")
            return

        self.send_response(response.status)
        for key, value in response.getheaders():
            lowered = key.lower()
            if lowered in HOP_BY_HOP or lowered in ("date", "server"):
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)
        conn.close()

    def do_GET(self):
        self._forward("GET")

    def do_POST(self):
        self._forward("POST")

    def do_PUT(self):
        self._forward("PUT")

    def do_DELETE(self):
        self._forward("DELETE")

    def do_HEAD(self):
        self._forward("HEAD")


def main() -> None:
    listen_port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_LISTEN_PORT
    target_port = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_TARGET_PORT

    server = ThreadingHTTPServer(("127.0.0.1", listen_port), Bridge)
    server.target_port = target_port
    print(
        f"bridging 127.0.0.1:{listen_port} -> {TARGET_HOST}:{target_port}\n"
        f"run the app with: --dart-define=YTM_BASE_URL=http://10.0.2.2:{listen_port}",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
