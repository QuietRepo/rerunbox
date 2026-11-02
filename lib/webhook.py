#!/usr/bin/env python3
"""RerunBox webhook: a tiny token-protected HTTP API to start/stop the loop.

Configuration comes from environment variables set by bin/rerunbox-webhook:
  WEBHOOK_TOKEN, WEBHOOK_BIND, WEBHOOK_PORT, STATE_DIR

Routes (all require the header  X-Webhook-Token: <token>  or
Authorization: Bearer <token>):
  POST /start            start relay, then feeder
  POST /stop             stop feeder, then relay
  POST /restart          stop then start
  POST /reset-position   forget the resume position and restart the feeder only
                         (the outbound connection stays up)
  GET  /status           JSON: service states and the clip that is playing

Only the stdlib is used. It shells out to `sudo systemctl` for the four
rerunbox units, which the installer permits through /etc/sudoers.d/rerunbox.
"""
import hmac
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("WEBHOOK_TOKEN", "")
BIND = os.environ.get("WEBHOOK_BIND", "127.0.0.1")
PORT = int(os.environ.get("WEBHOOK_PORT", "8787"))
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/rerunbox")
STATE_FILE = os.path.join(STATE_DIR, "feeder.state")

RELAY = "rerunbox-relay.service"
FEEDER = "rerunbox-feeder.service"


def systemctl(action, unit):
    try:
        result = subprocess.run(
            ["sudo", "-n", "systemctl", action, unit],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, str(exc)
    return result.returncode == 0, result.stderr.strip()


def is_active(unit):
    try:
        return subprocess.run(
            ["systemctl", "is-active", "--quiet", unit], timeout=10
        ).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def run_steps(steps):
    errors = []
    for action, unit in steps:
        ok, err = systemctl(action, unit)
        if not ok:
            errors.append(f"{action} {unit}: {err or 'failed'}")
            break  # don't carry on if an earlier step failed
    return not errors, "; ".join(errors)


def do_stop():
    return run_steps([("stop", FEEDER), ("stop", RELAY)])


def do_start():
    return run_steps([("start", RELAY), ("start", FEEDER)])


def do_restart():
    ok, err = do_stop()
    return (do_start() if ok else (ok, err))


def do_reset_position():
    try:
        os.remove(STATE_FILE)
    except FileNotFoundError:
        pass
    except OSError as exc:
        return False, str(exc)
    # Bounce only the feeder so the outbound connection stays up.
    return run_steps([("stop", FEEDER), ("start", FEEDER)])


def status():
    now_playing = None
    try:
        with open(STATE_FILE) as fh:
            now_playing = os.path.basename(fh.read().strip()) or None
    except OSError:
        pass
    return {
        "relay": "active" if is_active(RELAY) else "inactive",
        "feeder": "active" if is_active(FEEDER) else "inactive",
        "now_playing": now_playing,
    }


ROUTES = {
    ("POST", "/start"): (do_start, "loop starting"),
    ("POST", "/stop"): (do_stop, "loop stopping"),
    ("POST", "/restart"): (do_restart, "loop restarting"),
    ("POST", "/reset-position"): (do_reset_position, "resuming from the first file"),
}


class Handler(BaseHTTPRequestHandler):
    server_version = "RerunBox"
    sys_version = ""

    def _authorised(self):
        given = self.headers.get("X-Webhook-Token", "")
        if not given:
            auth = self.headers.get("Authorization", "")
            if auth.lower().startswith("bearer "):
                given = auth[7:].strip()
        return hmac.compare_digest(given.encode(), TOKEN.encode())

    def _send(self, code, body, ctype="text/plain"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _dispatch(self, method):
        if not self._authorised():
            return self._send(403, "Forbidden")
        if method == "GET" and self.path == "/status":
            return self._send(200, json.dumps(status()), "application/json")
        route = ROUTES.get((method, self.path))
        if not route:
            return self._send(404, "Not found")
        func, message = route
        ok, err = func()
        if ok:
            return self._send(200, f"OK: {message}")
        return self._send(500, err or "failed")

    def do_POST(self):
        self._dispatch("POST")

    def do_GET(self):
        self._dispatch("GET")

    def log_message(self, fmt, *args):  # systemd already timestamps; stay quiet
        pass


def main():
    if not TOKEN:
        sys.exit("WEBHOOK_TOKEN is not set; refusing to start an unauthenticated webhook")
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
