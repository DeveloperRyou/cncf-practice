#!/usr/bin/env python3
"""Local backend for the exam UI (stdlib only; started by scripts/exam.sh).

The UI (exam/web/) is either served from here or deployed as a static site
(e.g. Cloudflare Pages); either way it talks to this server for everything
local: the exam sheets in this clone, the repo's freshness, and the fixed
prepare step (down.sh, up.sh, <round>/setup.sh), and grading
(<round>/grade.sh, results saved to <round>/grade.json). It binds to
127.0.0.1 and only runs those scripts -- never arbitrary commands.

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
from datetime import datetime, timezone
from urllib.parse import parse_qs
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROUND_RE = re.compile(r"^[a-z0-9-]+/round-\d+$")
WEB = ROOT / "exam" / "web"
# Origins of deployed copies of the UI allowed to call this server.
ORIGINS = {o.strip().rstrip("/") for o in os.environ.get(
    "EXAM_ORIGINS", "https://cncf-practice.developerryou.workers.dev").split(",") if o.strip()}
API_VERSION = 2
PASS_MARK = 66
# Per-attempt files in a round directory; a new prepare archives them.
ATTEMPT_FILES = ("finished.json", "grade.json")
ITEM_RE = re.compile(r"^\s*(PASS|FAIL)\s+\[Q(\d+)\]\s+(\d+)\s+(.*)$")
SUM_RE = re.compile(r"^Q(\d+)\s+(\d+)\s*/\s*(\d+)\s*$")


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def write_json(path, obj):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(path)


class Job:
    """One background script at a time (prepare or grade), with its log."""

    def __init__(self):
        self.lock = threading.Lock()
        self.state, self.kind, self.round, self.log = "idle", None, None, collections.deque(maxlen=500)

    def snapshot(self):
        with self.lock:
            return {"state": self.state, "kind": self.kind, "round": self.round, "log": "".join(self.log)}

    def start(self, kind, rnd, script, on_done=None):
        with self.lock:
            if self.state == "running":
                return False
            self.state, self.kind, self.round = "running", kind, rnd
            self.log.clear()
        threading.Thread(target=self._run, args=(script, on_done), daemon=True).start()
        return True

    def _run(self, script, on_done):
        proc = subprocess.Popen(["bash", "-c", script], cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for line in proc.stdout:
            with self.lock:
                self.log.append(line)
        ok = proc.wait() == 0
        if on_done:
            try:
                ok = on_done(ok, self.snapshot()["log"]) and ok
            except Exception as e:  # keep the job from hanging in "running"
                with self.lock:
                    self.log.append(f"\n{type(e).__name__}: {e}\n")
                ok = False
        with self.lock:
            self.state = "ok" if ok else "failed"


def prepare_script(rnd, recreate):
    steps = (["./scripts/down.sh", "./scripts/up.sh"] if recreate else ["./scripts/up.sh"])
    steps.append(f"./{rnd}/setup.sh")
    return "set -e\n" + "\n".join(f"echo '$ {s}'; {s}" for s in steps)


def archive_attempt(rnd):
    """Move the previous attempt's answers and results into
    <round>/attempts/<timestamp>/ so a retake starts clean -- down.sh only
    wipes the cluster, not the answer files. Returns the archive path."""
    d = ROOT / rnd
    answers = d / "answers"
    moved = [p for p in answers.iterdir() if p.name != ".gitkeep"] if answers.is_dir() else []
    moved += [d / f for f in ATTEMPT_FILES if (d / f).exists()]
    if not moved:
        return None
    dest = d / "attempts" / datetime.now().strftime("%Y%m%d-%H%M%S")
    (dest / "answers").mkdir(parents=True)
    for p in moved:
        shutil.move(str(p), str(dest / ("answers" if p.parent == answers else "") / p.name))
    return dest.relative_to(ROOT)


def parse_grade(output, meta):
    """grade.sh's output -> per-question items and scores, annotated with the
    domain/topics from the round's meta.json."""
    qs = {}
    for line in output.splitlines():
        if m := ITEM_RE.match(line):
            q = qs.setdefault(m[2], {"items": []})
            q["items"].append({"pass": m[1] == "PASS", "points": int(m[3]), "desc": m[4].strip()})
        elif m := SUM_RE.match(line.strip()):
            qs.setdefault(m[1], {"items": []}).update(got=int(m[2]), max=int(m[3]))
    questions, domains = [], {}
    for n in sorted(qs, key=int):
        q = qs[n]
        q.setdefault("got", sum(i["points"] for i in q["items"] if i["pass"]))
        q.setdefault("max", sum(i["points"] for i in q["items"]))
        info = (meta.get("questions") or {}).get(n, {})
        questions.append({"n": n, "domain": info.get("domain"), "topics": info.get("topics", []), **q})
        if info.get("domain"):
            dom = domains.setdefault(info["domain"], {"domain": info["domain"], "got": 0, "max": 0, "questions": []})
            dom["got"] += q["got"]; dom["max"] += q["max"]; dom["questions"].append(n)
    total = sum(q["got"] for q in questions)
    total_max = sum(q["max"] for q in questions)
    return {
        "total": total, "max": total_max, "passMark": PASS_MARK,
        "passed": total_max > 0 and total * 100 >= PASS_MARK * total_max,
        "questions": questions, "domains": list(domains.values()),
    }


def grade(job, rnd):
    d = ROOT / rnd

    def done(ok, log):
        result = parse_grade(log, read_json(d / "meta.json") or {})
        if not result["questions"]:
            return False
        write_json(d / "grade.json", {"round": rnd, "gradedAt": now_iso(), **result, "output": log})
        return True
    return job.start("grade", rnd, f"./{rnd}/grade.sh", done)


def rounds():
    out = []
    for sheet in sorted(ROOT.glob("*/round-*/README.md")):
        rnd = f"{sheet.parent.parent.name}/{sheet.parent.name}"
        text = sheet.read_text()
        title = next((l[2:] for l in text.splitlines() if l.startswith("# ")), rnd)
        minutes = re.search(r"(\d+)\s*minutes", text)
        g = read_json(sheet.parent / "grade.json")
        out.append({
            "round": rnd,
            "cert": sheet.parent.parent.name,
            "title": title,
            "questions": len(re.findall(r"^## Question \d+", text, re.M)),
            "minutes": int(minutes.group(1)) if minutes else 40,
            "graded": (sheet.parent / "result.md").exists() or g is not None,
            "finished": (sheet.parent / "finished.json").exists(),
            "score": {"total": g["total"], "max": g["max"], "passed": g["passed"],
                      "gradedAt": g["gradedAt"]} if g else None,
            "attempts": len(list((sheet.parent / "attempts").glob("*/"))),
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
        elif path == "/api/result":
            rnd = parse_qs(query).get("round", [""])[0]
            if not ROUND_RE.match(rnd) or not (ROOT / rnd / "README.md").is_file():
                return self.send_json({"error": "unknown round"}, 404)
            self.send_json({
                "job": self.job.snapshot(),
                "finished": read_json(ROOT / rnd / "finished.json"),
                "grade": read_json(ROOT / rnd / "grade.json"),
            })
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
        if (not self.host_ok() or self.path not in ("/api/prepare", "/api/grade")
                or self.headers.get("X-Exam") != "1" or not self.allowed_origin()):
            return self.send_error(403)
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except ValueError:
            return self.send_error(400)
        rnd = str(req.get("round", ""))
        script = "setup.sh" if self.path == "/api/prepare" else "grade.sh"
        if not ROUND_RE.match(rnd) or not (ROOT / rnd / script).is_file():
            return self.send_json({"error": "unknown round"}, 400)
        if self.job.snapshot()["state"] == "running":
            return self.send_json({"error": "another prepare/grade job is already running"}, 409)

        if self.path == "/api/prepare":
            archived = archive_attempt(rnd)
            self.job.start("prepare", rnd, prepare_script(rnd, bool(req.get("recreate", True))))
            if archived:
                with self.job.lock:
                    self.job.log.appendleft(f"previous attempt archived to {archived}/\n")
        else:
            # The exam UI's End button: mark the attempt finished, then grade.
            s = req.get("session")
            if isinstance(s, dict):
                num = lambda k: s.get(k) if isinstance(s.get(k), (int, float)) else None
                started, ended = num("startedAt"), num("endedAt")
                iso = lambda ms: datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat(timespec="seconds") if ms else None
                write_json(ROOT / rnd / "finished.json", {
                    "round": rnd, "startedAt": iso(started), "endedAt": iso(ended) or now_iso(),
                    "minutes": num("minutes"),
                    "usedSeconds": round((ended - started) / 1000) if started and ended else None,
                    "flagged": sorted(str(k) for k, v in (s.get("flags") or {}).items() if v),
                })
            grade(self.job, rnd)
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
