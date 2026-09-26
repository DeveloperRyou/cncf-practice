#!/usr/bin/env python3
"""Local backend for the exam UI (stdlib only; started by scripts/exam.sh).

The UI (exam/web/) is either served from here or deployed as a static site
(e.g. Cloudflare Pages); either way it talks to this server for everything
local: the exam sheets in this clone, the repo's freshness, and the fixed
prepare step (down.sh, up.sh, <round>/setup.sh). It binds to 127.0.0.1 and
only runs those scripts -- never arbitrary commands.

Browser-side guards: the Host header must be localhost (defeats DNS
rebinding), and POSTs must carry X-Exam, which forces a CORS preflight that
is approved only for this server's own origin and EXAM_ORIGINS.
"""
import argparse
import collections
import json
import re
import shutil
import socket
import subprocess
import os
import threading
import time
from urllib.parse import parse_qs
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROUND_RE = re.compile(r"^[a-z0-9-]+/round-\d+$")
WEB = ROOT / "exam" / "web"
# Origins of deployed copies of the UI allowed to call this server.
ORIGINS = {o.strip().rstrip("/") for o in os.environ.get(
    "EXAM_ORIGINS", "https://cncf-practice.pages.dev").split(",") if o.strip()}
API_VERSION = 1


class Job:
    def __init__(self):
        self.lock = threading.Lock()
        self.state, self.round, self.log = "idle", None, collections.deque(maxlen=500)

    def snapshot(self):
        with self.lock:
            return {"state": self.state, "round": self.round, "log": "".join(self.log)}

    def start(self, rnd, recreate):
        with self.lock:
            if self.state == "running":
                return False
            self.state, self.round = "running", rnd
            self.log.clear()
        steps = (["./scripts/down.sh", "./scripts/up.sh"] if recreate else ["./scripts/up.sh"])
        steps.append(f"./{rnd}/setup.sh")
        script = "set -e\n" + "\n".join(f"echo '$ {s}'; {s}" for s in steps)
        threading.Thread(target=self._run, args=(script,), daemon=True).start()
        return True

    def _run(self, script):
        proc = subprocess.Popen(["bash", "-c", script], cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in proc.stdout:
            with self.lock:
                self.log.append(line)
        ok = proc.wait() == 0
        with self.lock:
            self.state = "ok" if ok else "failed"


def rounds():
    out = []
    for sheet in sorted(ROOT.glob("*/round-*/README.md")):
        rnd = f"{sheet.parent.parent.name}/{sheet.parent.name}"
        text = sheet.read_text()
        title = next((l[2:] for l in text.splitlines() if l.startswith("# ")), rnd)
        minutes = re.search(r"(\d+)\s*minutes", text)
        out.append({
            "round": rnd,
            "cert": sheet.parent.parent.name,
            "title": title,
            "questions": len(re.findall(r"^## Question \d+", text, re.M)),
            "minutes": int(minutes.group(1)) if minutes else 40,
            "graded": (sheet.parent / "result.md").exists(),
        })
    return out


class RepoStatus:
    """How far this clone is behind its upstream; `git fetch` is slow, so
    it runs in the background at most once a minute."""

    def __init__(self):
        self.lock, self.fetched_at, self.fetching, self.fetch_ok = threading.Lock(), 0.0, False, None

    def _git(self, *args, timeout=5):
        r = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() if r.returncode == 0 else None

    def _fetch(self):
        try:
            ok = self._git("fetch", "--quiet", timeout=20) is not None
        except subprocess.TimeoutExpired:
            ok = False
        with self.lock:
            self.fetching, self.fetch_ok, self.fetched_at = False, ok, time.time()

    def get(self):
        with self.lock:
            if not self.fetching and time.time() - self.fetched_at > 60:
                self.fetching = True
                threading.Thread(target=self._fetch, daemon=True).start()
            fetch_ok = self.fetch_ok
        counts = self._git("rev-list", "--left-right", "--count", "HEAD...@{u}")
        ahead, behind = map(int, counts.split()) if counts else (None, None)
        return {
            "branch": self._git("rev-parse", "--abbrev-ref", "HEAD"),
            "upstream": self._git("rev-parse", "--abbrev-ref", "@{u}"),
            "behind": behind, "ahead": ahead, "fetched": fetch_ok,
        }


def port_open(port):
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def docker_ok():
    try:
        return subprocess.run(["docker", "info"], capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


class Handler(SimpleHTTPRequestHandler):
    job = Job()
    repo = RepoStatus()
    term_port = 7681
    port = 8000

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(WEB), **kw)

    def log_message(self, *a):
        pass

    def allowed_origin(self):
        origin = self.headers.get("Origin")
        own = {f"http://localhost:{self.port}", f"http://127.0.0.1:{self.port}"}
        return origin if origin in ORIGINS | own else None

    def host_ok(self):
        host = self.headers.get("Host", "")
        return host in (f"localhost:{self.port}", f"127.0.0.1:{self.port}")

    def cors(self):
        origin = self.allowed_origin()
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")

    def send_body(self, body, ctype, code=200):
        self.send_response(code)
        self.cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, code=200):
        self.send_body(json.dumps(obj).encode(), "application/json", code)

    def do_OPTIONS(self):
        if not self.host_ok() or not self.allowed_origin():
            return self.send_error(403)
        self.send_response(204)
        self.cors()
        self.send_header("Access-Control-Allow-Methods", "GET, POST")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Exam")
        # Chrome's Private/Local Network Access preflight for public -> localhost.
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.end_headers()

    def do_GET(self):
        if not self.host_ok():
            return self.send_error(403)
        path, _, query = self.path.partition("?")
        if path == "/api/env":
            self.send_json({
                "version": API_VERSION,
                "root": str(ROOT),
                "repo": self.repo.get(),
                "termPort": self.term_port,
                "terminal": port_open(self.term_port),
                "docker": docker_ok(),
                "kind": shutil.which("kind") is not None,
                "kubectl": shutil.which("kubectl") is not None,
            })
        elif path == "/api/rounds":
            self.send_json(rounds())
        elif path == "/api/job":
            self.send_json(self.job.snapshot())
        elif path == "/api/sheet":
            rnd = parse_qs(query).get("round", [""])[0]
            sheet = ROOT / rnd / "README.md"
            if not ROUND_RE.match(rnd) or not sheet.is_file():
                return self.send_json({"error": "unknown round"}, 404)
            self.send_body(sheet.read_bytes(), "text/markdown; charset=utf-8")
        elif path in ("/", "/index.html"):
            super().do_GET()
        else:
            self.send_error(404)

    def do_POST(self):
        if (not self.host_ok() or self.path != "/api/prepare"
                or self.headers.get("X-Exam") != "1" or not self.allowed_origin()):
            return self.send_error(403)
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except ValueError:
            return self.send_error(400)
        rnd = str(req.get("round", ""))
        if not ROUND_RE.match(rnd) or not (ROOT / rnd / "setup.sh").is_file():
            return self.send_json({"error": "unknown round"}, 400)
        if not self.job.start(rnd, bool(req.get("recreate", True))):
            return self.send_json({"error": "a prepare job is already running"}, 409)
        self.send_json(self.job.snapshot())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--term-port", type=int, default=7681)
    args = ap.parse_args()
    Handler.term_port, Handler.port = args.term_port, args.port
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
