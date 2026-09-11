#!/usr/bin/env python3
"""AdsiCRM self-update daemon.

Runs on the HOST, never in a container — a container's own process tree dies
the instant `docker compose up -d` recreates it, so nothing living inside the
backend or frontend container can safely orchestrate replacing that same
container. This daemon is the one piece of the update mechanism that has to
sit outside Docker entirely, so it survives the compose recreation it
triggers.

The backend container reaches it over host.docker.internal, which resolves to
the docker bridge's gateway IP (e.g. 172.18.0.1) — NOT loopback — so this
process has to bind 0.0.0.0 to be reachable at all; a socket bound to
127.0.0.1 only accepts traffic arriving on the loopback interface itself; a
container reaching in over the bridge on a different interface than the
process is listening on would just be refused, "unreachable" is where it
went. Since binding 0.0.0.0 also means it is technically visible to the
public network interface, this is guarded by two independent layers: the
shared-secret token below, and an IP allowlist that rejects anything outside
private/loopback ranges before it ever gets to the token check — so even if
the host's own firewall isn't configured, nothing on the public internet can
reach past this daemon.

Authenticated with a shared secret (UPDATER_TOKEN, generated once by
setup.sh).

Installed and started as a systemd service by setup.sh (unit:
adsicrm-updater), so it restarts on crash and starts on boot without needing
a container or a login shell to keep it alive.
"""
import ipaddress
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CLIENT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UPDATER_DIR = os.path.join(CLIENT_DIR, "updater")
APP_JSON = os.path.join(CLIENT_DIR, "app.json")
CHECK_SCRIPT = os.path.join(UPDATER_DIR, "check.sh")
UPDATE_SCRIPT = os.path.join(UPDATER_DIR, "update.sh")
STATUS_FILE = os.path.join(UPDATER_DIR, ".status")
LOG_FILE = os.path.join(UPDATER_DIR, "update.log")

TOKEN = os.environ.get("UPDATER_TOKEN", "")
PORT = int(os.environ.get("UPDATER_PORT", "8765"))

update_lock = threading.Lock()


def read_current_version():
    try:
        with open(APP_JSON) as f:
            return json.load(f).get("version")
    except Exception:
        return None


def read_status():
    try:
        with open(STATUS_FILE) as f:
            return f.read().strip() or "idle"
    except FileNotFoundError:
        return "idle"


def run_check():
    result = subprocess.run(
        ["sh", CHECK_SCRIPT],
        cwd=CLIENT_DIR,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return json.loads(result.stdout.strip())


def start_update():
    # start_new_session detaches the child from this process's session, so it
    # keeps running even across the daemon's own systemd restarts, and its
    # stdout/stderr go to a log file since nothing will be left to read a pipe.
    with open(LOG_FILE, "ab") as log:
        subprocess.Popen(
            ["sh", UPDATE_SCRIPT],
            cwd=CLIENT_DIR,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )


class Handler(BaseHTTPRequestHandler):
    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _client_allowed(self):
        try:
            return ipaddress.ip_address(self.client_address[0]).is_private
        except ValueError:
            return False

    def _authorized(self):
        return bool(TOKEN) and self.headers.get("X-Updater-Token") == TOKEN

    def do_GET(self):
        if not self._client_allowed():
            self._json({"error": "forbidden"}, 403)
            return
        if not self._authorized():
            self._json({"error": "unauthorized"}, 401)
            return

        if self.path == "/version":
            self._json({"version": read_current_version()})
        elif self.path == "/check":
            try:
                self._json(run_check())
            except Exception as e:
                self._json({"error": str(e)}, 500)
        elif self.path == "/status":
            self._json({"status": read_status()})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        if not self._client_allowed():
            self._json({"error": "forbidden"}, 403)
            return
        if not self._authorized():
            self._json({"error": "unauthorized"}, 401)
            return

        if self.path != "/update":
            self._json({"error": "not found"}, 404)
            return

        with update_lock:
            if read_status() == "updating":
                self._json({"status": "already_running"}, 409)
                return
            try:
                start_update()
            except Exception as e:
                self._json({"error": str(e)}, 500)
                return

        self._json({"status": "started"})

    def log_message(self, format, *args):
        pass  # keep the systemd journal quiet; update.sh's own log is update.log


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("UPDATER_TOKEN is not set — refusing to start with no auth.")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.serve_forever()
