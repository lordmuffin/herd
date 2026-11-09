#!/usr/bin/env python3
"""herd serve: herd's streams as a small web API and page. Python 3 stdlib only.

Started by `herd serve`, which passes every path and setting as a flag. The server never parses
herdr or git output: it runs bin/herd subcommands that print JSON (argv lists, never a shell),
and serves that JSON as it is. docs/serve-api.md has the contract.

  GET /, /static/*   files from web/
  GET /api/snapshot  `herd status -j -a`, cached for 2 s
  GET /api/show      `herd show -j <repo> <branch> <what>`, for a stream of the snapshot
  GET /api/events    Server-Sent Events: a `snapshot` event when it changes
  GET /api/config    the page's non-secret settings: the relay app URL and this host's name
  GET /sw.js         web/sw.js, at the root so the service worker's scope is the whole page
  GET /healthz       ok, no auth

Every /api route needs `Authorization: Bearer <token>` (reader or controller, from
<state dir>/serve-tokens.json); /api/events also takes it as ?t=, since EventSource can't set
headers. Requests whose Host is not the bound address, localhost or a HERD_SERVE_HOSTS entry
are refused (DNS rebinding).
"""

import argparse
import hmac
import ipaddress
import json
import mimetypes
import os
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

SNAPSHOT_TTL = 2.0      # seconds a snapshot is reused
EVENT_POLL = 5.0        # seconds between snapshot checks on an event stream
KEEPALIVE = 20.0        # seconds between keep-alive comments on an event stream
NUDGE_POLL = 0.25       # seconds between checks of the nudge file's mtime
CMD_TIMEOUT = 30        # seconds a herd subcommand may take
SHOW_WHAT = ("diff", "progress", "screen", "log")
TYPES = {".webmanifest": "application/manifest+json", ".js": "text/javascript",
         ".css": "text/css", ".svg": "image/svg+xml", ".html": "text/html"}

stopping = threading.Event()


def log(msg):
    print("herd serve: " + msg, file=sys.stderr, flush=True)


def is_loopback(addr):
    if addr == "localhost":
        return True
    try:
        return ipaddress.ip_address(addr).is_loopback
    except ValueError:
        return False


# --- tokens --------------------------------------------------------------------------------------

def load_tokens(path, create):
    """The {reader, controller} tokens in path, made (mode 0600) if create and they don't exist."""
    if not os.path.exists(path):
        if not create:
            return None
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tokens = {"reader": secrets.token_urlsafe(32), "controller": secrets.token_urlsafe(32)}
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(tokens, f)
            f.write("\n")
        log("wrote new reader and controller tokens to " + path)
        return tokens
    if os.stat(path).st_mode & 0o077:
        os.chmod(path, 0o600)
        log("tightened %s to mode 0600" % path)
    with open(path) as f:
        tokens = json.load(f)
    if not all(isinstance(tokens.get(k), str) and tokens[k] for k in ("reader", "controller")):
        raise ValueError("%s needs a reader and a controller token" % path)
    return tokens


# --- herd ------------------------------------------------------------------------------------------

class HerdError(Exception):
    pass


class Herd:
    """Runs bin/herd subcommands and keeps the last snapshot for SNAPSHOT_TTL."""

    def __init__(self, argv0, base, nudge):
        self.argv0, self.base, self.nudge = argv0, base, nudge
        self.lock = threading.Lock()
        self.snap, self.snap_at, self.snap_nudge = None, 0.0, None

    def run(self, *args):
        try:
            p = subprocess.run(self.argv0 + list(args), stdin=subprocess.DEVNULL,
                               capture_output=True, timeout=CMD_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise HerdError("herd %s took longer than %d s" % (args[0], CMD_TIMEOUT))
        except OSError as e:
            raise HerdError("could not run herd: %s" % e)
        if p.returncode != 0:
            raise HerdError(p.stderr.decode(errors="replace").strip() or "herd %s failed" % args[0])
        return p.stdout

    def nudge_mtime(self):
        try:
            return os.stat(self.nudge).st_mtime_ns
        except OSError:
            return None

    def snapshot(self):
        """`herd status -j -a` as compact JSON bytes. A new nudge mtime makes it stale at once."""
        with self.lock:
            nudge = self.nudge_mtime()
            if self.snap is None or nudge != self.snap_nudge or time.monotonic() - self.snap_at > SNAPSHOT_TTL:
                out = self.run("status", "-j", "-a", "-b", self.base)
                try:
                    doc = json.loads(out)
                except ValueError:
                    raise HerdError("herd status -j -a printed no JSON")
                self.snap = json.dumps(doc, separators=(",", ":")).encode()
                self.snap_at, self.snap_nudge = time.monotonic(), nudge
            return self.snap

    def show(self, repo, branch, what):
        """`herd show -j` for a stream the snapshot lists. A KeyError if it lists none."""
        doc = json.loads(self.snapshot())
        for r in doc.get("repos", []):
            if r.get("path") == repo and any(s.get("branch") == branch for s in r.get("streams", [])):
                return self.run("show", "-j", "-b", self.base, repo, branch, what)
        raise KeyError(branch)


# --- HTTP ------------------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "herd-serve"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    # The server sets these on the class: app (an App).
    app = None

    def log_message(self, fmt, *args):
        pass  # requests are logged by log_request, without their query string

    def log_request(self, code="-", size="-"):
        path = urlsplit(self.path).path  # never the query: /api/events?t= carries a token
        log('%s "%s %s" %s' % (self.address_string(), self.command, path, code))

    def send(self, code, body, ctype="text/plain; charset=utf-8", headers=()):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, code, obj, headers=()):
        body = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send(code, body, "application/json", (("Cache-Control", "no-store"),) + tuple(headers))

    def host_ok(self):
        host = self.headers.get("Host", "")
        if host.startswith("["):
            host = host[1:].split("]", 1)[0]
        elif host.count(":") == 1:
            host = host.split(":", 1)[0]
        return host.lower() in self.app.hosts

    def role(self, query):
        """reader or controller for the request's token, or None."""
        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth[:7].lower() == "bearer " else None
        if token is None and query is not None:
            token = (query.get("t") or [None])[0]
        if not token:
            return None
        found = None
        for name, want in self.app.tokens.items():
            if hmac.compare_digest(token.encode(), want.encode()):
                found = name
        return found

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self.host_ok():
            return self.send(403, "herd serve: unknown Host\n")
        url = urlsplit(self.path)
        path, query = url.path, parse_qs(url.query)
        if path == "/healthz":
            return self.send(200, "ok\n")
        if path.startswith("/api/"):
            if self.role(query if path == "/api/events" else None) is None:
                return self.send_json(401, {"error": "a reader or controller token is required"},
                                      (("WWW-Authenticate", 'Bearer realm="herd"'),))
            if path == "/api/snapshot":
                return self.api_snapshot()
            if path == "/api/show":
                return self.api_show(query)
            if path == "/api/events":
                return self.api_events()
            if path == "/api/config":
                return self.send_json(200, self.app.config)
            return self.send_json(404, {"error": "no such route"})
        if path == "/" or path == "/index.html":
            return self.static("index.html")
        if path == "/sw.js":
            return self.static("sw.js")
        if path.startswith("/static/"):
            return self.static(path[len("/static/"):])
        return self.send(404, "not found\n")

    def do_POST(self):
        if not self.host_ok():
            return self.send(403, "herd serve: unknown Host\n")
        # No write routes yet. --read-only (app.read_only) will turn them all off.
        self.send_json(405, {"error": "read-only" if self.app.read_only else "no such route"},
                       (("Allow", "GET, HEAD"),))

    do_PUT = do_DELETE = do_PATCH = do_POST

    def static(self, rel):
        web = self.app.web
        full = os.path.realpath(os.path.join(web, rel))
        if not full.startswith(web + os.sep) or not os.path.isfile(full):
            return self.send(404, "not found\n")
        ext = os.path.splitext(full)[1]
        ctype = TYPES.get(ext) or mimetypes.guess_type(full)[0] or "application/octet-stream"
        if ctype.startswith("text/") or ctype.endswith(("json", "+xml")):
            ctype += "; charset=utf-8"
        with open(full, "rb") as f:
            body = f.read()
        self.send(200, body, ctype, (("Content-Security-Policy", "default-src 'self'"),
                                     ("Cache-Control", "no-cache")))

    def api_snapshot(self):
        try:
            self.send_json(200, self.app.herd.snapshot())
        except HerdError as e:
            self.send_json(502, {"error": str(e)})

    def api_show(self, query):
        repo, branch, what = (query.get(k, [""])[0] for k in ("repo", "branch", "what"))
        if not repo or not branch or what not in SHOW_WHAT:
            return self.send_json(400, {"error": "needs repo, branch and what=" + "|".join(SHOW_WHAT)})
        try:
            self.send_json(200, self.app.herd.show(repo, branch, what))
        except KeyError:
            self.send_json(404, {"error": "%s is not a herd stream of %s" % (branch, repo)})
        except HerdError as e:
            self.send_json(502, {"error": str(e)})

    def api_events(self):
        """A snapshot at once, then again whenever it changes: checked every EVENT_POLL s and as
        soon as the nudge file's mtime changes. A keep-alive comment every KEEPALIVE s."""
        herd = self.app.herd
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "close")
        self.end_headers()
        last, nudge = None, herd.nudge_mtime()
        next_poll = next_alive = 0.0
        try:
            self.wfile.write(b"retry: 3000\n\n")
            while not stopping.is_set():
                now = time.monotonic()
                n = herd.nudge_mtime()
                if n != nudge or now >= next_poll:
                    nudge, next_poll = n, now + EVENT_POLL
                    try:
                        snap = herd.snapshot()
                    except HerdError as e:
                        self.wfile.write(b"event: error\ndata: " + json.dumps({"error": str(e)}).encode() + b"\n\n")
                    else:
                        if snap != last:
                            last = snap
                            self.wfile.write(b"event: snapshot\ndata: " + snap + b"\n\n")
                            next_alive = now + KEEPALIVE
                if now >= next_alive:
                    self.wfile.write(b": keep-alive\n\n")
                    next_alive = now + KEEPALIVE
                self.wfile.flush()
                stopping.wait(NUDGE_POLL)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # the page went away


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class App:
    def __init__(self, args):
        self.web = os.path.realpath(args.web)
        self.read_only = args.read_only
        self.herd = Herd(args.herd, args.base, os.path.join(args.state_dir, "serve.nudge"))
        self.hosts = {"localhost", args.listen.lower()}
        self.hosts.update(h.strip().lower() for h in args.hosts.replace(",", " ").split() if h.strip())
        self.tokens = None
        # Only these reach the page through /api/config: nothing secret, and nothing the relay
        # keeps in its own config (herd.conf's HERD_RELAY_APP_URL and HERD_RELAY_HOST).
        self.config = {"relay_app_url": args.relay_app_url or None,
                       "relay_host": args.relay_host or socket.gethostname().split(".")[0]}


def parse_args(argv):
    p = argparse.ArgumentParser(prog="herd serve", description="herd's streams as a web page and API")
    p.add_argument("--listen", help="address to bind (default 127.0.0.1)")
    p.add_argument("--conf-listen", default="", help=argparse.SUPPRESS)  # HERD_SERVE_LISTEN
    p.add_argument("--port", type=int, default=8380)
    p.add_argument("--read-only", action="store_true", help="turn off every write route")
    p.add_argument("--hosts", default="", help="more Host names to accept (HERD_SERVE_HOSTS)")
    p.add_argument("--state-dir", required=True)
    p.add_argument("--web", required=True, help="the web/ directory")
    p.add_argument("--relay-app-url", default="", help="the Herdr Mobile app's URL (HERD_RELAY_APP_URL)")
    p.add_argument("--relay-host", default="", help="this machine's name in the relay (HERD_RELAY_HOST)")
    p.add_argument("--base", default="origin/main", help="base ref for herd status and show")
    p.add_argument("--herd", nargs="+", required=True, help="argv that runs bin/herd (last flag)")
    args = p.parse_args(argv)
    args.explicit = args.listen is not None
    if not args.explicit:
        args.listen = args.conf_listen or "127.0.0.1"
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    app = App(args)
    tokens_path = os.path.join(args.state_dir, "serve-tokens.json")
    try:
        if is_loopback(args.listen):
            app.tokens = load_tokens(tokens_path, create=True)
        else:
            # Off loopback, only on purpose and only with tokens made beforehand.
            if not args.explicit:
                log("refusing to listen on %s from herd.conf alone: pass --listen %s" % (args.listen, args.listen))
                return 2
            app.tokens = load_tokens(tokens_path, create=False)
            if app.tokens is None:
                log("refusing to listen on %s without tokens: run herd serve once on loopback first "
                    "(it writes %s)" % (args.listen, tokens_path))
                return 2
    except (OSError, ValueError) as e:
        log("tokens: %s" % e)
        return 1
    if not os.path.isdir(app.web):
        log("no web directory at " + app.web)
        return 1

    Handler.app = app
    Server.address_family = socket.AF_INET6 if ":" in args.listen else socket.AF_INET
    try:
        httpd = Server((args.listen, args.port), Handler)
    except OSError as e:
        log("cannot listen on %s port %d: %s" % (args.listen, args.port, e))
        return 1
    host, port = httpd.server_address[:2]
    app.hosts.add(str(host).lower())

    def stop(signum, frame):
        stopping.set()
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    shown = "[%s]" % host if ":" in str(host) else host
    log("listening on http://%s:%d/%s" % (shown, port, " (read-only)" if args.read_only else ""))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stopping.set()
        httpd.server_close()
    log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
