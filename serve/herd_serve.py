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
  GET /api/personas  `herd personas -j` for a repo: the New sheet's persona picker
  GET /healthz       ok, no auth

  POST /api/start, /api/draft, /api/fanout, /api/plan, /api/plan-resume, /api/done, /api/rm
                     run the matching herd command (controller token only; --read-only turns
                     them all off). Each POST gets a request id and one line in
                     <state dir>/serve-audit.jsonl, which never holds the prompt text.

Every /api route needs `Authorization: Bearer <token>` (reader or controller, from
<state dir>/serve-tokens.json); /api/events also takes it as ?t=, since EventSource can't set
headers. Requests whose Host is not the bound address, localhost or a HERD_SERVE_HOSTS entry
are refused (DNS rebinding).
"""

import argparse
import fnmatch
import hashlib
import hmac
import ipaddress
import json
import mimetypes
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

SNAPSHOT_TTL = 2.0      # seconds a snapshot is reused
EVENT_POLL = 5.0        # seconds between snapshot checks on an event stream
KEEPALIVE = 20.0        # seconds between keep-alive comments on an event stream
NUDGE_POLL = 0.25       # seconds between checks of the nudge file's mtime
CMD_TIMEOUT = 30        # seconds a herd subcommand may take
SHOW_WHAT = ("diff", "progress", "screen", "log")
MAX_BODY = 64 * 1024    # bytes a POST body may have
DRY_TTL = 15 * 60       # seconds a fan-out preview's hash stays good
# Seconds each write may take: a draft is a headless agent session, a fan-out starts many agents.
WRITE_TIMEOUT = {"start": 300, "draft": 900, "fanout": 900, "done": 300, "rm": 120, "plan": 60}
# POST routes and their Handler methods. All of them need the controller token.
WRITES = {"/api/start": "w_start", "/api/draft": "w_draft", "/api/fanout": "w_fanout",
          "/api/plan": "w_plan", "/api/plan-resume": "w_plan_resume", "/api/done": "w_done",
          "/api/rm": "w_rm"}
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

    def call(self, args, timeout, cwd=None, stdin=None, env=None, argv0=None):
        """Runs herd (or argv0) with args; (exit code, stdout and stderr interleaved). Raises
        HerdError only when it could not run or ran out of time."""
        try:
            p = subprocess.run((argv0 or self.argv0) + list(args), cwd=cwd, env=env,
                               input=(stdin or "").encode(), stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise HerdError("herd %s took longer than %d s" % (args[0], timeout))
        except OSError as e:
            raise HerdError("could not run herd: %s" % e)
        return p.returncode, p.stdout.decode(errors="replace")

    def poke(self):
        """After a write: the next snapshot is fresh, and open event streams get it at once."""
        with self.lock:
            self.snap = None
        try:
            with open(self.nudge, "a"):
                pass
            os.utime(self.nudge)
        except OSError:
            pass

    def personas(self, repo):
        """[{name, description}] from `herd personas -j`, with the repo's own personas if given."""
        out = self.run_in(repo or "/", "personas", "-j")
        try:
            return [{"name": p["name"], "description": p.get("description")} for p in json.loads(out)]
        except (ValueError, KeyError, TypeError):
            raise HerdError("herd personas -j printed no JSON")

    def run_in(self, cwd, *args):
        rc, out = self.call(args, CMD_TIMEOUT, cwd=cwd)
        if rc != 0:
            raise HerdError(out.strip() or "herd %s failed" % args[0])
        return out

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


# --- writes: checks ---------------------------------------------------------------------------------

class Refused(Exception):
    """A request herd serve turns down before running anything: (HTTP code, message)."""

    def __init__(self, code, msg):
        super().__init__(msg)
        self.code, self.msg = code, msg


def git_ok(repo, *args):
    """True if `git -C repo <args>` exits 0. Only the exit code is read, never git's output."""
    try:
        return subprocess.run(["git", "-C", repo] + list(args), stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=CMD_TIMEOUT).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def agent_name(branch):
    """bin/herd's agent_name: fix/foo.bar -> fix-foo-bar."""
    n = re.sub(r"[^a-z0-9_-]", "", branch.translate(str.maketrans("/._", "---")).lower())
    return re.sub(r"^[-_0-9]", "", n)[:32]


def text_field(body, key, required=True, limit=None, one_line=False):
    v = body.get(key)
    if v is None or v == "":
        if required:
            raise Refused(400, "%s is required" % key)
        return ""
    if not isinstance(v, str):
        raise Refused(400, "%s must be a string" % key)
    if limit and len(v) > limit:
        raise Refused(400, "%s is longer than %d characters" % (key, limit))
    if one_line and ("\n" in v or "\r" in v or "\0" in v):
        raise Refused(400, "%s must be one line" % key)
    if "\0" in v:
        raise Refused(400, "%s holds a NUL byte" % key)
    return v


def digest(text):
    """What the audit log keeps of a prompt: its length and sha256, never the text."""
    return len(text), hashlib.sha256(text.encode()).hexdigest()


def batch_hash(repo, name, data):
    """A fan-out preview's hash: the file's place and its bytes, so an edit makes it stale."""
    return hashlib.sha256(repo.encode() + b"\0" + name.encode() + b"\0" + data).hexdigest()


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
            role = self.role(query if path == "/api/events" else None)
            if role is None:
                return self.send_json(401, {"error": "a reader or controller token is required"},
                                      (("WWW-Authenticate", 'Bearer realm="herd"'),))
            if path == "/api/snapshot":
                return self.api_snapshot()
            if path == "/api/show":
                return self.api_show(query)
            if path == "/api/events":
                return self.api_events()
            if path == "/api/config":
                return self.send_json(200, dict(self.app.config, role=role))
            if path == "/api/personas":
                return self.api_personas(query)
            return self.send_json(404, {"error": "no such route"})
        if path == "/" or path == "/index.html":
            return self.static("index.html")
        if path == "/sw.js":
            return self.static("sw.js")
        if path.startswith("/static/"):
            return self.static(path[len("/static/"):])
        return self.send(404, "not found\n")

    def do_POST(self):
        # Whatever happens, the body may be left unread: never reuse this connection.
        self.close_connection = True
        if not self.host_ok():
            return self.send(403, "herd serve: unknown Host\n")
        url = urlsplit(self.path)
        path, query = url.path, parse_qs(url.query)
        if self.app.read_only:
            return self.send_json(405, {"ok": False, "error": "herd serve runs read-only (--read-only)"},
                                  (("Allow", "GET, HEAD"),))
        if path not in WRITES:
            return self.send_json(404, {"ok": False, "error": "no such route"})
        rid = secrets.token_hex(8)
        role = self.role(None)
        # The handler fills in repo, branch and the length and sha256 of any prompt-like text.
        audit = {"repo": None, "branch": None}
        headers = [("X-Request-Id", rid)]
        try:
            if role is None:
                headers.append(("WWW-Authenticate", 'Bearer realm="herd"'))
                raise Refused(401, "the controller token is required")
            if role != "controller":
                raise Refused(403, "this needs the controller token; a reader token can only look")
            body = self.read_body()
            code, res = getattr(self, WRITES[path])(body, query, audit)
        except Refused as e:
            code, res = e.code, {"ok": False, "output": "", "error": e.msg}
        except HerdError as e:
            code, res = 502, {"ok": False, "output": "", "error": str(e)}
        res["request_id"] = rid
        rec = {"ts": datetime.now(timezone.utc).isoformat(timespec="seconds"), "request_id": rid,
               "token_role": role, "route": path}
        rec.update(audit)
        rec.update(ok=res.get("ok") is True, status=code)
        self.app.audit(rec)
        self.send_json(code, res, headers)

    def do_PUT(self):
        self.close_connection = True
        if not self.host_ok():
            return self.send(403, "herd serve: unknown Host\n")
        self.send_json(405, {"error": "use GET or POST"}, (("Allow", "GET, HEAD, POST"),))

    do_DELETE = do_PATCH = do_PUT

    def read_body(self):
        """The request's JSON object, at most MAX_BODY bytes."""
        try:
            n = int(self.headers.get("Content-Length", ""))
        except ValueError:
            raise Refused(411, "a Content-Length is required")
        if n < 0 or n > MAX_BODY:
            raise Refused(413, "the body is over %d KB" % (MAX_BODY // 1024))
        ctype = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
        if ctype != "application/json":
            raise Refused(415, "send the body as application/json")
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            raise Refused(400, "the body is not JSON")
        if not isinstance(body, dict):
            raise Refused(400, "the body must be a JSON object")
        return body

    # --- writes: the arguments --------------------------------------------------------------------

    def repo_field(self, body, audit):
        """The repo of the request, if herd serve knows it: one in the snapshot or HERD_SERVE_REPOS."""
        repo = text_field(body, "repo", limit=4096, one_line=True)
        audit["repo"] = repo
        real = os.path.realpath(repo)
        if real not in self.app.known_repos():
            raise Refused(404, "%s is not a repo herd serve knows (one with streams, or in HERD_SERVE_REPOS)" % repo)
        if not os.path.isdir(real):
            raise Refused(404, "%s is gone" % repo)
        return real

    def stream_of(self, repo, branch):
        """The snapshot's stream `branch` of repo, or Refused 404."""
        for r in json.loads(self.app.herd.snapshot()).get("repos", []):
            if os.path.realpath(r.get("path", "")) == repo:
                for s in r.get("streams", []):
                    if s.get("branch") == branch:
                        return s
        raise Refused(404, "%s is not a herd stream of %s" % (branch, repo))

    def new_branch(self, repo, body, audit):
        """A branch for a new stream, checked the way `herd draft` checks a task file's lines."""
        branch = text_field(body, "branch", limit=200, one_line=True)
        audit["branch"] = branch
        if not re.fullmatch(r"[^\s@:]+", branch) or branch.startswith("-") \
                or not git_ok(repo, "check-ref-format", "--branch", branch):
            raise Refused(400, "%s is not a valid branch name" % branch)
        if git_ok(repo, "show-ref", "--quiet", "--verify", "refs/heads/" + branch) \
                or git_ok(repo, "show-ref", "--quiet", "--verify", "refs/remotes/origin/" + branch):
            raise Refused(409, "branch %s already exists, pick another name" % branch)
        if not agent_name(branch):
            raise Refused(400, "%s gives no agent name" % branch)
        return branch

    def persona_field(self, repo, body):
        """A persona `herd personas` lists for the repo, "none", or "" for herd's default."""
        persona = text_field(body, "persona", required=False, limit=200, one_line=True)
        if persona in ("", "none"):
            return persona
        if persona not in {p["name"] for p in self.app.herd.personas(repo)}:
            raise Refused(400, "unknown persona %s (see herd personas)" % persona)
        return persona

    def branches_field(self, repo, body, audit):
        bs = body.get("branches")
        if not isinstance(bs, list) or not bs or len(bs) > 100 or not all(isinstance(b, str) and b for b in bs):
            raise Refused(400, "branches must be a list of branch names")
        audit["branch"] = bs
        for b in bs:
            self.stream_of(repo, b)
        return bs

    def root_file(self, repo, body, key, pattern, audit):
        """(path, name) of a file named in body[key]: a pattern file in the repo root, nowhere else."""
        name = text_field(body, key, limit=200, one_line=True)
        audit["file"] = name
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) or not fnmatch.fnmatchcase(name, pattern):
            raise Refused(400, "%s must be a %s file in the repo root" % (key, pattern))
        path = os.path.join(repo, name)
        if os.path.lexists(path) and os.path.dirname(os.path.realpath(path)) != repo:
            raise Refused(400, "%s points outside the repo root" % name)
        return path, name

    def result(self, rc, out, **more):
        res = {"ok": rc == 0, "output": out, "error": None}
        if rc != 0:
            lines = [l for l in out.strip().splitlines() if l.strip()]
            res["error"] = lines[-1] if lines else "herd exited %d" % rc
        res.update(more)
        return 200, res

    def herd_opts(self):
        """The options every agent-starting herd run gets from herd.conf: base and kind."""
        return ["-b", self.app.herd.base, "-k", self.app.kind]

    def agent_tail(self):
        return ["--"] + self.app.agent_args if self.app.agent_args else []

    # --- writes: the routes -----------------------------------------------------------------------

    def w_start(self, body, query, audit):
        prompt = text_field(body, "prompt", required=False, limit=MAX_BODY)
        audit["prompt_len"], audit["prompt_sha256"] = digest(prompt)
        repo = self.repo_field(body, audit)
        branch = self.new_branch(repo, body, audit)
        persona = self.persona_field(repo, body)
        if not prompt.strip() or prompt.strip() == "--":
            raise Refused(400, "the prompt is empty")
        args = ["-r", repo] + self.herd_opts() + (["-P", persona] if persona else [])
        rc, out = self.app.herd.call(args + [branch, prompt] + self.agent_tail(), WRITE_TIMEOUT["start"])
        self.app.herd.poke()
        return self.result(rc, out, branch=branch)

    def w_draft(self, body, query, audit):
        goal = text_field(body, "goal", required=False, limit=MAX_BODY)
        audit["goal_len"], audit["goal_sha256"] = digest(goal)
        repo = self.repo_field(body, audit)
        if not body.get("output"):
            body["output"] = "Tasks.herd" if not os.path.lexists(os.path.join(repo, "Tasks.herd")) \
                else time.strftime("Tasks-%Y%m%d-%H%M.herd")
        path, name = self.root_file(repo, body, "output", "Tasks*.herd", audit)
        if os.path.lexists(path):
            raise Refused(409, "%s already exists, name another Tasks-<name>.herd" % name)
        if not goal.strip():
            raise Refused(400, "the goal is empty")
        # The goal goes in on stdin ("-"): as an argument, a goal that names a file would be read.
        rc, out = self.app.herd.call(["draft", "-r", repo, "-b", self.app.herd.base, "-o", path, "-"],
                                     WRITE_TIMEOUT["draft"], stdin=goal)
        if rc != 0 or not os.path.isfile(path):
            return self.result(rc or 1, out, file=name)
        with open(path, "rb") as f:
            data = f.read()
        drc, dry = self.app.herd.call(["-n", "-r", repo, "-f", path], CMD_TIMEOUT)
        more = {"file": name, "text": data.decode(errors="replace"), "dry_run": dry}
        if drc == 0:
            more["hash"] = self.app.issue_dry(batch_hash(repo, name, data))
        return self.result(rc, out, **more)

    def w_fanout(self, body, query, audit):
        repo = self.repo_field(body, audit)
        path, name = self.root_file(repo, body, "file", "*.herd", audit)
        if not os.path.isfile(path):
            raise Refused(404, "no task file %s in %s" % (name, repo))
        with open(path, "rb") as f:
            want = batch_hash(repo, name, f.read())
        if (query.get("dry") or [""])[0] in ("1", "true") or body.get("dry") is True:
            rc, out = self.app.herd.call(["-n", "-r", repo, "-f", path], CMD_TIMEOUT)
            more = {"file": name}
            if rc == 0:
                more["hash"] = self.app.issue_dry(want)
            return self.result(rc, out, **more)
        got = body.get("hash")
        if not isinstance(got, str) or not hmac.compare_digest(got, want) or not self.app.take_dry(got):
            raise Refused(409, "no current preview of %s: preview it again (?dry=1) and send its hash" % name)
        args = ["-r", repo] + self.herd_opts() + ["-f", path] + self.agent_tail()
        rc, out = self.app.herd.call(args, WRITE_TIMEOUT["fanout"])
        self.app.herd.poke()
        return self.result(rc, out, file=name)

    def plugin_action(self, action, repo, env):
        """The herdr plugin's own action, which opens its pane in a herdr tab: a plan's driver must
        outlive this request and this server, so herdr runs it, not us."""
        if not self.app.plugin:
            raise Refused(501, "no herdr plugin (plugin/herd-plugin.sh) next to herd, so no herdr tab to run it in")
        full = dict(os.environ, HERD_REPO=repo, **env)
        rc, out = self.app.herd.call(["action", action], WRITE_TIMEOUT["plan"], env=full,
                                     argv0=[self.app.herd.argv0[0], self.app.plugin])
        self.app.herd.poke()
        return rc, out

    def w_plan(self, body, query, audit):
        text = text_field(body, "plan_text", required=False, limit=MAX_BODY)
        audit["plan_len"], audit["plan_sha256"] = digest(text)
        repo = self.repo_field(body, audit)
        branch = self.new_branch(repo, body, audit)
        persona = self.persona_field(repo, body)
        verify = text_field(body, "verify", required=False, limit=1000, one_line=True)
        if not text.strip():
            raise Refused(400, "the plan is empty")
        inbox = os.path.join(repo, ".herd", "inbox")
        path = os.path.join(inbox, branch + ".md")
        if not os.path.realpath(path).startswith(os.path.realpath(inbox) + os.sep):
            raise Refused(400, "%s would land outside .herd/inbox" % branch)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text if text.endswith("\n") else text + "\n")
        self.app.exclude_inbox(repo)
        env = {"HERD_BRANCH": branch, "HERD_PLAN_FILE": path}
        if verify:
            env["HERD_PLAN_VERIFY"] = verify
        if persona:
            env["HERD_PLAN_PERSONA"] = persona
        rc, out = self.plugin_action("plan", repo, env)
        note = "the plan runs in a new herdr tab of %s; its card shows up here once it starts\n" % os.path.basename(repo)
        return self.result(rc, (note if rc == 0 else "") + out, branch=branch, file=os.path.relpath(path, repo))

    def w_plan_resume(self, body, query, audit):
        repo = self.repo_field(body, audit)
        branch = text_field(body, "branch", limit=200, one_line=True)
        audit["branch"] = branch
        if not self.stream_of(repo, branch).get("plan_detail"):
            raise Refused(409, "%s has no plan to resume" % branch)
        rc, out = self.plugin_action("plan-resume", repo, {"HERD_BRANCH": branch})
        note = "the plan resumes in a new herdr tab\n"
        return self.result(rc, (note if rc == 0 else "") + out, branch=branch)

    def w_done(self, body, query, audit):
        repo = self.repo_field(body, audit)
        bs = self.branches_field(repo, body, audit)
        rc, out = self.app.herd.call(["done", "-r", repo, "-b", self.app.herd.base] + bs, WRITE_TIMEOUT["done"])
        self.app.herd.poke()
        return self.result(rc, out)

    def w_rm(self, body, query, audit):
        repo = self.repo_field(body, audit)
        bs = self.branches_field(repo, body, audit)
        if body.get("confirm") != "discard":
            raise Refused(400, 'discarding needs confirm: "discard"')
        rc, out = self.app.herd.call(["rm", "-r", repo] + bs, WRITE_TIMEOUT["rm"])
        self.app.herd.poke()
        return self.result(rc, out)

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

    def api_personas(self, query):
        repo = (query.get("repo") or [""])[0]
        if repo:
            repo = os.path.realpath(repo)
            if repo not in self.app.known_repos():
                return self.send_json(404, {"error": "not a repo herd serve knows"})
        try:
            self.send_json(200, {"personas": self.app.herd.personas(repo or None)})
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
        self.kind, self.agent_args = args.kind, args.agent_arg
        self.plugin = args.plugin or None
        self.repos = [os.path.realpath(r) for r in args.repos.replace(",", " ").split() if r.strip()]
        self.audit_path = os.path.join(args.state_dir, "serve-audit.jsonl")
        self.audit_lock = threading.Lock()
        self.dry, self.dry_lock = {}, threading.Lock()  # fan-out preview hash -> expiry
        # Only these reach the page through /api/config: nothing secret, and nothing the relay
        # keeps in its own config (herd.conf's HERD_RELAY_APP_URL and HERD_RELAY_HOST).
        self.config = {"relay_app_url": args.relay_app_url or None,
                       "relay_host": args.relay_host or socket.gethostname().split(".")[0],
                       "read_only": self.read_only, "repos": self.repos}

    def known_repos(self):
        """Real paths of the repos writes may touch: the snapshot's and HERD_SERVE_REPOS."""
        doc = json.loads(self.herd.snapshot())
        return {os.path.realpath(r["path"]) for r in doc.get("repos", []) if r.get("path")} | set(self.repos)

    def issue_dry(self, h):
        with self.dry_lock:
            now = time.monotonic()
            self.dry = {k: t for k, t in self.dry.items() if t > now}
            self.dry[h] = now + DRY_TTL
        return h

    def take_dry(self, h):
        """True once for a hash a preview issued, until it expires."""
        with self.dry_lock:
            t = self.dry.pop(h, None)
        return t is not None and t > time.monotonic()

    def exclude_inbox(self, repo):
        """Keeps .herd/inbox/ out of the repo's git status, through its info/exclude."""
        try:
            p = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                               capture_output=True, timeout=CMD_TIMEOUT)
            if p.returncode != 0:
                return
            excl = os.path.join(p.stdout.decode().strip(), "info", "exclude")
            have = open(excl).read() if os.path.exists(excl) else ""
            if "/.herd/inbox/" not in have.split("\n"):
                os.makedirs(os.path.dirname(excl), exist_ok=True)
                with open(excl, "a") as f:
                    f.write(("" if have.endswith("\n") or not have else "\n") + "/.herd/inbox/\n")
        except (OSError, subprocess.TimeoutExpired):
            pass

    def audit(self, rec):
        """One line per POST in serve-audit.jsonl (mode 0600). Never the prompt, plan or goal."""
        line = json.dumps(rec, separators=(",", ":")) + "\n"
        try:
            with self.audit_lock:
                fd = os.open(self.audit_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
                with os.fdopen(fd, "a") as f:
                    f.write(line)
        except OSError as e:
            log("audit log: %s" % e)


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
    p.add_argument("--kind", default="claude", help="agent kind for the agents writes start (HERD_KIND)")
    p.add_argument("--agent-arg", action="append", default=[], help="an extra agent arg (HERD_AGENT_ARGS)")
    p.add_argument("--repos", default="", help="more repos to start streams in (HERD_SERVE_REPOS)")
    p.add_argument("--plugin", default="", help="plugin/herd-plugin.sh, which opens plan tabs in herdr")
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
