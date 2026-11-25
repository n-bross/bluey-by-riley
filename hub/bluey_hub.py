#!/usr/bin/env python3
"""Bluey Hub: notes, todos and a Hermes gateway for the Bluey apps, without the laptop.

Runs next to Hermes Agent (e.g. on an always-on home server) and is reached over Tailscale.
Python 3.9+ with optional viewer dependencies in screen/requirements.txt.

    bluey_hub.py serve [--host 127.0.0.1] [--port 8766]   # the HTTP API (see API below)
    bluey_hub.py note add "text" | note list | note show ID | note edit ID "text" | note rm ID
    bluey_hub.py todo add "title" [--due YYYY-MM-DD] [--list NAME] [--notes TEXT]
    bluey_hub.py todo list [--all] | todo done ID | todo undo ID | todo edit ID [--title ..] [--due ..|--due none] | todo rm ID

Data lives in $BLUEY_HUB_HOME (default ~/bluey-hub):
    notes/<id>.md     one note per file; the first line is its title (like Raycast Notes)
    todos.json        all todos
    config.json       {"key": "<bearer key for the apps>", "tailnet_logins": ["you@example.com"],
                       "hermes_url": "...", "hermes_key": "..."}
                      hermes_url/hermes_key default to Hermes' own API server settings in ~/.hermes/.env.

Auth: either "Authorization: Bearer <key>", or (recommended) put the hub behind `tailscale serve` and list your
Tailscale login in tailnet_logins: Tailscale adds the caller's identity (Tailscale-User-Login) to every request,
so your own devices need no key at all. The hub only listens on 127.0.0.1, so that header can't come from outside.

API (every route but /health needs "Authorization: Bearer <key>"):
    GET    /health
    GET    /notes                     -> [{id, title, preview, pinned, created, updated}]
    GET    /notes/{id}                -> {id, title, body, pinned, created, updated}
    POST   /notes   {body, pinned?}   -> note
    PUT    /notes/{id} {body?, pinned?}
    DELETE /notes/{id}
    GET    /todos[?all=1]             -> [{id, title, notes, due, list, done, created, updated, completed}]
    POST   /todos   {title, notes?, due?, list?}
    PATCH  /todos/{id} {title?, notes?, due?, list?, done?}
    DELETE /todos/{id}
    GET    /changes                   -> {notes: <latest update>, todos: <latest update>} (cheap polling)
    *      /hermes/<path>             -> proxied to Hermes' API server (key added here), streaming included
"""
import argparse
import fcntl
import json
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

VERSION = "1"
HOME = Path(os.environ.get("BLUEY_HUB_HOME", Path.home() / "bluey-hub"))
NOTES = HOME / "notes"
TODOS = HOME / "todos.json"
CONFIG = HOME / "config.json"
LOCK = HOME / ".lock"
ID_RE = re.compile(r"^[a-z0-9-]{6,64}$")


def now():
    return round(time.time(), 3)


def ensure_home():
    NOTES.mkdir(parents=True, exist_ok=True)
    os.chmod(HOME, 0o700)


@contextmanager
def locked():
    ensure_home()
    with open(LOCK, "a+") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def write_atomic(path, text):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def hermes_env():
    """Hermes' own API server settings, so the hub needs no copy of its key."""
    env = {}
    path = Path.home() / ".hermes" / ".env"
    if path.exists():
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            m = re.match(r"\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*)\s*$", line)
            if m:
                env[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return env


def load_config():
    ensure_home()
    cfg = {}
    if CONFIG.exists():
        cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    if not cfg.get("key"):
        cfg["key"] = secrets.token_hex(32)
        write_atomic(CONFIG, json.dumps(cfg, indent=2))
    env = hermes_env()
    cfg.setdefault("hermes_url", "http://127.0.0.1:%s" % env.get("API_SERVER_PORT", "8642"))
    cfg.setdefault("hermes_key", env.get("API_SERVER_KEY", ""))
    return cfg


# ---------------------------------------------------------------- notes

def note_title(body):
    for line in body.splitlines():
        t = line.strip().lstrip("#").strip()
        if t:
            return t[:120]
    return "Untitled"


def read_note(nid):
    path = NOTES / (nid + ".md")
    if not ID_RE.match(nid) or not path.exists():
        return None
    raw = path.read_text(encoding="utf-8")
    meta, body = {}, raw
    if raw.startswith("<!--bluey "):
        end = raw.find("-->\n")
        if end > 0:
            try:
                meta = json.loads(raw[len("<!--bluey "):end])
            except ValueError:
                meta = {}
            body = raw[end + 4:]
    st = path.stat()
    return {"id": nid, "title": note_title(body), "body": body,
            "pinned": bool(meta.get("pinned", False)),
            "created": meta.get("created", st.st_mtime), "updated": meta.get("updated", st.st_mtime)}


def save_note(note):
    meta = {"pinned": note["pinned"], "created": note["created"], "updated": note["updated"]}
    write_atomic(NOTES / (note["id"] + ".md"), "<!--bluey %s-->\n%s" % (json.dumps(meta), note["body"]))


def list_notes():
    ensure_home()
    out = []
    for p in NOTES.glob("*.md"):
        n = read_note(p.stem)
        if n:
            preview = " ".join(l.strip() for l in n["body"].splitlines()[1:] if l.strip())[:140]
            out.append({k: n[k] for k in ("id", "title", "pinned", "created", "updated")} | {"preview": preview})
    out.sort(key=lambda n: (not n["pinned"], -n["updated"]))
    return out


def create_note(body, pinned=False):
    with locked():
        t = now()
        n = {"id": uuid.uuid4().hex[:12], "body": body, "pinned": bool(pinned), "created": t, "updated": t}
        save_note(n)
        return read_note(n["id"])


def update_note(nid, body=None, pinned=None):
    with locked():
        n = read_note(nid)
        if not n:
            return None
        if body is not None:
            n["body"] = body
        if pinned is not None:
            n["pinned"] = bool(pinned)
        n["updated"] = now()
        save_note(n)
        return read_note(nid)


def delete_note(nid):
    with locked():
        path = NOTES / (nid + ".md")
        if ID_RE.match(nid) and path.exists():
            path.unlink()
            return True
        return False


# ---------------------------------------------------------------- todos

def read_todos():
    if not TODOS.exists():
        return []
    return json.loads(TODOS.read_text(encoding="utf-8"))


def write_todos(todos):
    write_atomic(TODOS, json.dumps(todos, indent=1, ensure_ascii=False))


DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def clean_due(due):
    if due in (None, "", "none", "null"):
        return None
    if not DATE_RE.match(str(due)):
        raise ValueError("due must be YYYY-MM-DD")
    return str(due)


def list_todos(include_done=False):
    todos = read_todos()
    if not include_done:
        cutoff = now() - 86400  # done items stay visible for a day
        todos = [t for t in todos if not t["done"] or (t.get("completed") or 0) > cutoff]
    todos.sort(key=lambda t: (t["done"], t["due"] or "9999", t["created"]))
    return todos


def create_todo(title, notes="", due=None, list_name="Inbox"):
    title = (title or "").strip()
    if not title:
        raise ValueError("title is required")
    with locked():
        todos = read_todos()
        t = now()
        todo = {"id": uuid.uuid4().hex[:10], "title": title[:300], "notes": notes or "", "due": clean_due(due),
                "list": (list_name or "Inbox").strip() or "Inbox", "done": False,
                "created": t, "updated": t, "completed": None}
        todos.append(todo)
        write_todos(todos)
        return todo


def update_todo(tid, **changes):
    with locked():
        todos = read_todos()
        for todo in todos:
            if todo["id"] == tid:
                if "title" in changes and changes["title"] is not None:
                    todo["title"] = str(changes["title"]).strip()[:300] or todo["title"]
                if "notes" in changes and changes["notes"] is not None:
                    todo["notes"] = str(changes["notes"])
                if "due" in changes:
                    todo["due"] = clean_due(changes["due"])
                if "list" in changes and changes["list"]:
                    todo["list"] = str(changes["list"]).strip()
                if "done" in changes and changes["done"] is not None:
                    todo["done"] = bool(changes["done"])
                    todo["completed"] = now() if todo["done"] else None
                todo["updated"] = now()
                write_todos(todos)
                return todo
        return None


def delete_todo(tid):
    with locked():
        todos = read_todos()
        kept = [t for t in todos if t["id"] != tid]
        if len(kept) == len(todos):
            return False
        write_todos(kept)
        return True


def changes():
    notes = max([n["updated"] for n in list_notes()] or [0])
    todos = max([t["updated"] for t in read_todos()] or [0])
    return {"notes": notes, "todos": todos}


# ---------------------------------------------------------------- HTTP

def authorized(headers, cfg):
    got = headers.get("Authorization", "")
    if got and secrets.compare_digest(got, "Bearer " + cfg["key"]):
        return True
    login = headers.get("Tailscale-User-Login", "").strip().lower()
    allowed = [value.strip().lower() for value in cfg.get("tailnet_logins", []) if value.strip()]
    return bool(login) and login in allowed


class Handler(BaseHTTPRequestHandler):
    server_version = "BlueyHub/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet; no request bodies or keys in logs
        sys.stderr.write("%s %s\n" % (self.command, self.path.split("?")[0]))

    def send_json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 5_000_000:
            raise ValueError("body too large")
        raw = self.rfile.read(length) if length else b""
        return json.loads(raw.decode("utf-8")) if raw else {}

    def authorized(self):
        return authorized(self.headers, self.server.cfg)

    def route(self, method):
        path = self.path.split("?")[0].rstrip("/") or "/"
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        if path == "/health":
            return self.send_json(200, {"ok": True, "version": VERSION, "hermes": bool(self.server.cfg.get("hermes_key")),
                                        "you": self.headers.get("Tailscale-User-Login") or None,
                                        "authorized": self.authorized()})
        if not self.authorized():
            return self.send_json(401, {"error": "unauthorized"})
        if path.startswith("/hermes/"):
            return self.proxy(method, path[len("/hermes"):], query)
        try:
            parts = path.strip("/").split("/")
            if parts[0] == "changes" and method == "GET":
                return self.send_json(200, changes())
            if parts[0] == "notes":
                if len(parts) == 1 and method == "GET":
                    return self.send_json(200, list_notes())
                if len(parts) == 1 and method == "POST":
                    b = self.body_json()
                    return self.send_json(201, create_note(str(b.get("body", "")), b.get("pinned", False)))
                if len(parts) == 2:
                    nid = parts[1]
                    if method == "GET":
                        n = read_note(nid)
                    elif method == "PUT":
                        b = self.body_json()
                        n = update_note(nid, b.get("body"), b.get("pinned"))
                    elif method == "DELETE":
                        return self.send_json(200 if delete_note(nid) else 404, {})
                    else:
                        n = None
                    return self.send_json(200, n) if n else self.send_json(404, {"error": "no such note"})
            if parts[0] == "todos":
                if len(parts) == 1 and method == "GET":
                    return self.send_json(200, list_todos("all=1" in query))
                if len(parts) == 1 and method == "POST":
                    b = self.body_json()
                    return self.send_json(201, create_todo(b.get("title"), b.get("notes", ""), b.get("due"), b.get("list", "Inbox")))
                if len(parts) == 2:
                    tid = parts[1]
                    if method == "PATCH":
                        b = self.body_json()
                        allowed = {k: b[k] for k in ("title", "notes", "due", "list", "done") if k in b}
                        t = update_todo(tid, **allowed)
                        return self.send_json(200, t) if t else self.send_json(404, {"error": "no such todo"})
                    if method == "DELETE":
                        return self.send_json(200 if delete_todo(tid) else 404, {})
            return self.send_json(404, {"error": "not found"})
        except ValueError as e:
            return self.send_json(400, {"error": str(e)})

    def proxy(self, method, path, query):
        cfg = self.server.cfg
        if not cfg.get("hermes_key"):
            return self.send_json(503, {"error": "Hermes API server isn't configured on this host"})
        url = cfg["hermes_url"].rstrip("/") + path + ("?" + query if query else "")
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length) if length else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + cfg["hermes_key"])
        for h in ("Content-Type", "Accept", "Idempotency-Key", "X-Hermes-Session-Id", "X-Hermes-Session-Key"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        try:
            resp = urllib.request.urlopen(req, timeout=600)
        except urllib.error.HTTPError as e:
            resp = e
        except (urllib.error.URLError, OSError) as e:
            return self.send_json(502, {"error": "Hermes isn't answering: %s" % e})
        ctype = resp.headers.get("Content-Type", "application/json")
        self.send_response(resp.status if hasattr(resp, "status") else resp.code)
        self.send_header("Content-Type", ctype)
        if "text/event-stream" in ctype:
            # Stream server-sent events through as they arrive.
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                while True:
                    chunk = resp.readline()
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True
            return
        body = resp.read()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_PATCH(self):
        self.route("PATCH")

    def do_DELETE(self):
        self.route("DELETE")


def serve(host, port):
    cfg = load_config()
    screen_enabled = bool(cfg.get("hermes_screen"))
    address = ("127.0.0.1", 0) if screen_enabled else (host, port)
    with ThreadingHTTPServer(address, Handler) as httpd:
        httpd.daemon_threads = True
        httpd.cfg = cfg
        print("Bluey Hub %s on http://%s:%d (data in %s)" % (VERSION, host, port, HOME), flush=True)
        if not screen_enabled:
            httpd.serve_forever()
            return
        from bluey_screen import serve_screen

        worker = Thread(target=httpd.serve_forever, daemon=True)
        worker.start()
        try:
            serve_screen(host, port, httpd, cfg, authorized)
        finally:
            httpd.shutdown()
            worker.join()


# ---------------------------------------------------------------- CLI (for Hermes and you)

def main(argv=None):
    p = argparse.ArgumentParser(prog="bluey-hub", description="Bluey's notes and todos.")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8766)
    sub.add_parser("key", help="print the app key (for pairing the apps)")

    n = sub.add_parser("note").add_subparsers(dest="action", required=True)
    na = n.add_parser("add"); na.add_argument("text"); na.add_argument("--pin", action="store_true")
    n.add_parser("list")
    ns = n.add_parser("show"); ns.add_argument("id")
    ne = n.add_parser("edit"); ne.add_argument("id"); ne.add_argument("text")
    nap = n.add_parser("append"); nap.add_argument("id"); nap.add_argument("text")
    nr = n.add_parser("rm"); nr.add_argument("id")

    t = sub.add_parser("todo").add_subparsers(dest="action", required=True)
    ta = t.add_parser("add"); ta.add_argument("title"); ta.add_argument("--due"); ta.add_argument("--list", default="Inbox"); ta.add_argument("--notes", default="")
    tl = t.add_parser("list"); tl.add_argument("--all", action="store_true")
    for name in ("done", "undo", "rm"):
        x = t.add_parser(name); x.add_argument("id")
    te = t.add_parser("edit"); te.add_argument("id"); te.add_argument("--title"); te.add_argument("--due"); te.add_argument("--list"); te.add_argument("--notes")

    a = p.parse_args(argv)
    out = None
    if a.cmd == "serve":
        return serve(a.host, a.port)
    if a.cmd == "key":
        print(load_config()["key"]); return 0
    if a.cmd == "note":
        if a.action == "add": out = create_note(a.text, a.pin)
        elif a.action == "list": out = list_notes()
        elif a.action == "show": out = read_note(a.id)
        elif a.action == "edit": out = update_note(a.id, a.text)
        elif a.action == "append":
            cur = read_note(a.id)
            out = update_note(a.id, (cur["body"].rstrip("\n") + "\n" + a.text) if cur else None) if cur else None
        elif a.action == "rm": out = {"deleted": delete_note(a.id)}
    if a.cmd == "todo":
        if a.action == "add": out = create_todo(a.title, a.notes, a.due, a.list)
        elif a.action == "list": out = list_todos(a.all)
        elif a.action in ("done", "undo"): out = update_todo(a.id, done=(a.action == "done"))
        elif a.action == "rm": out = {"deleted": delete_todo(a.id)}
        elif a.action == "edit":
            ch = {k: getattr(a, k) for k in ("title", "list", "notes") if getattr(a, k) is not None}
            if a.due is not None: ch["due"] = a.due
            out = update_todo(a.id, **ch)
    if out is None:
        print("not found", file=sys.stderr); return 1
    print(json.dumps(out, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
