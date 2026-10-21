"""Tests for logbook-bridge, logbook_mcp.py and logbook-session-hook.

Run: python -m unittest discover -s logbook/tests
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
LOGBOOK = os.path.dirname(HERE)


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


bridge_mod = load("logbook_bridge", os.path.join(LOGBOOK, "logbook-bridge"))
mcp_mod = load("logbook_mcp", os.path.join(LOGBOOK, "logbook_mcp.py"))

HOSTILE = '"); (shell-command "touch /tmp/pwned") ("\\ %(delete-file "x") ${title}\n* heading'


def write_script(path, body):
    with open(path, "w") as f:
        f.write(body)
    os.chmod(path, 0o755)


class BridgeFixture(unittest.TestCase):
    """Runs a real bridge on an ephemeral port with a configurable emacsclient."""

    emacsclient_body = None

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.token_file = os.path.join(self.tmp, "token")
        with open(self.token_file, "w") as f:
            f.write("s3cret\n")
        self.spool_dir = os.path.join(self.tmp, "spool")
        self.record = os.path.join(self.tmp, "record.jsonl")
        self.emacsclient = os.path.join(self.tmp, "emacsclient")
        write_script(self.emacsclient, self.emacsclient_body.format(
            record=self.record, spool=os.path.join(self.spool_dir, "request.json"),
            python=sys.executable, el=os.path.join(LOGBOOK, "claude-logbook.el"),
            roam=os.path.join(self.tmp, "roam")))
        bridge = bridge_mod.Bridge(self.emacsclient, self.spool_dir, self.token_file)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), bridge_mod.make_handler(bridge))
        self.server.RequestHandlerClass.log_message = lambda *a: None
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]

    def post(self, path, payload, token="s3cret"):
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(self.url + path, data=json.dumps(payload).encode(),
                                         headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as e:
            return e.code, json.load(e)


# Records argv and the spooled request, then answers like emacsclient would.
FAKE_EMACSCLIENT = textwrap.dedent("""\
    #!{python}
    import json, sys
    with open("{spool}") as f:
        request = json.load(f)
    with open("{record}", "a") as f:
        f.write(json.dumps({{"argv": sys.argv[1:], "request": request}}) + "\\n")
    if request.get("title") == "fail":
        sys.stderr.write("*ERROR*: claude-logbook: boom\\n")
        sys.exit(1)
    print('"0ac34b25-cc04-4b24-8827-8d2e5ab899b6"')
    """)


class TestBridge(BridgeFixture):
    emacsclient_body = FAKE_EMACSCLIENT

    def records(self):
        with open(self.record) as f:
            return [json.loads(line) for line in f]

    def test_health(self):
        with urllib.request.urlopen(self.url + "/health") as response:
            self.assertEqual(json.load(response), {"ok": True})

    def test_requires_token(self):
        self.assertEqual(self.post("/create", {"title": "x"}, token=None)[0], 401)
        self.assertEqual(self.post("/create", {"title": "x"}, token="wrong")[0], 401)
        self.assertFalse(os.path.exists(self.record))

    def test_eval_argument_is_constant(self):
        status, reply = self.post("/create", {"title": HOSTILE})
        self.assertEqual((status, reply["ok"]), (200, True))
        status, _ = self.post("/append", {"id": reply["id"], "title": HOSTILE, "text": HOSTILE})
        self.assertEqual(status, 200)
        records = self.records()
        for record in records:
            self.assertEqual(record["argv"], ["--eval", "(claude-logbook-dispatch)"])
        self.assertEqual(records[0]["request"], {"op": "create", "title": HOSTILE})
        self.assertEqual(records[1]["request"],
                         {"op": "append", "id": reply["id"], "title": HOSTILE, "text": HOSTILE})
        self.assertEqual(os.listdir(self.spool_dir), [])
        self.assertEqual(os.stat(self.spool_dir).st_mode & 0o777, 0o700)

    def test_validation(self):
        self.assertEqual(self.post("/create", {"title": ""})[0], 400)
        self.assertEqual(self.post("/create", {"title": 3})[0], 400)
        self.assertEqual(self.post("/append", {"id": "../x", "title": "t", "text": "x"})[0], 400)
        self.assertEqual(self.post("/eval", {"title": "x"})[0], 404)
        self.assertFalse(os.path.exists(self.record))

    def test_emacs_error_propagates(self):
        status, reply = self.post("/create", {"title": "fail"})
        self.assertEqual(status, 502)
        self.assertIn("boom", reply["error"])


# Stands in for emacsclient by running the real claude-logbook.el in batch Emacs.
BATCH_EMACS = textwrap.dedent("""\
    #!/bin/sh
    [ "$1 $2" = "--eval (claude-logbook-dispatch)" ] || exit 99
    exec emacs --batch -Q -l "{el}" \\
      --eval '(setq org-roam-directory "{roam}" claude-logbook-spool-file "{spool}"
                    org-id-locations-file "{roam}/../org-id-locations")' \\
      --eval '(prin1 (prog1 (claude-logbook-dispatch) (org-id-locations-save)))' 2>/dev/null
    """)


class TestEndToEnd(BridgeFixture):
    """MCP tool functions -> bridge -> spool -> claude-logbook.el in real Emacs."""

    emacsclient_body = BATCH_EMACS

    def setUp(self):
        super().setUp()
        os.makedirs(os.path.join(self.tmp, "roam"))
        self.session_file = os.path.join(self.tmp, "session")
        self.state_file = os.path.join(self.tmp, "state", "sessions.json")
        patches = {"SESSION_FILE": self.session_file, "STATE_FILE": self.state_file}
        for name, value in patches.items():
            old = getattr(mcp_mod, name)
            setattr(mcp_mod, name, value)
            self.addCleanup(setattr, mcp_mod, name, old)
        env = {"LOGBOOK_URL": self.url, "LOGBOOK_TOKEN": "s3cret",
               "LOGBOOK_SESSION_FILE": self.session_file}
        for name, value in env.items():
            old = os.environ.get(name)
            os.environ[name] = value
            self.addCleanup(lambda n=name, o=old: os.environ.pop(n) if o is None
                            else os.environ.__setitem__(n, o))

    def start_session(self, session_id):
        subprocess.run([sys.executable, os.path.join(LOGBOOK, "logbook-session-hook")],
                       input=json.dumps({"session_id": session_id, "source": "startup"}),
                       text=True, check=True, env=os.environ)

    def roam_files(self):
        return sorted(os.listdir(os.path.join(self.tmp, "roam")))

    def read_roam(self, name):
        with open(os.path.join(self.tmp, "roam", name)) as f:
            return f.read()

    def test_session_lifecycle(self):
        self.start_session("session-a")
        entry = mcp_mod.create_entry("logbook test")
        self.assertIn("already exists", mcp_mod.create_entry("logbook test"))
        mcp_mod.append_entry(entry, "test", "test 1 2 3\n* detail\nmore")
        [name] = self.roam_files()
        self.assertRegex(name, r"^\d{6}_CLAUDE_logbook_test\.org$")
        content = self.read_roam(name)
        self.assertTrue(content.startswith(":PROPERTIES:\n:ID:       %s\n:END:\n"
                                           "#+title: [claude] logbook test\n"
                                           "#+filetags: :claude:\n\n* [" % entry))
        self.assertRegex(content, r"\] test\ntest 1 2 3\n\*\* detail\nmore\n$")

        # /clear: new session id -> new entry, old one is no longer writable
        self.start_session("session-b")
        with self.assertRaises(mcp_mod.ToolError):
            mcp_mod.append_entry(entry, "x", "y")
        with self.assertRaises(mcp_mod.ToolError):
            mcp_mod.append_entry("other", "x", "y")
        second = mcp_mod.create_entry("logbook test")
        self.assertNotEqual(second, entry)
        self.assertEqual(len(self.roam_files()), 2)
        self.assertIn("%s_CLAUDE_logbook_test-1.org" % name[:6], self.roam_files())

        # --resume: the original session id maps back to the original entry
        self.start_session("session-a")
        mcp_mod.append_entry(entry, "resumed", "again")
        self.assertTrue(self.read_roam(name).endswith("] resumed\nagain\n"))

    def test_hostile_input_is_stored_verbatim(self):
        self.start_session("session-h")
        canary = os.path.join(self.tmp, "canary")
        payload = '"); (make-empty-file "%s") ("%%(make-empty-file "%s")' % (canary, canary)
        entry = mcp_mod.create_entry(payload)
        mcp_mod.append_entry(entry, payload, payload)
        self.assertFalse(os.path.exists(canary))
        [name] = self.roam_files()
        content = self.read_roam(name)
        self.assertIn("#+title: [claude] " + payload + "\n", content)
        self.assertTrue(content.endswith("] %s\n%s\n" % (payload, payload)))

    def test_missing_session(self):
        with self.assertRaises(mcp_mod.ToolError):
            mcp_mod.create_entry("x")


class TestMcpProtocol(unittest.TestCase):
    def rpc(self, messages, env=None):
        proc = subprocess.run(
            [sys.executable, os.path.join(LOGBOOK, "logbook_mcp.py")],
            input="".join(json.dumps(m) + "\n" for m in messages),
            capture_output=True, text=True, env=dict(os.environ, **(env or {})), check=True)
        return [json.loads(line) for line in proc.stdout.splitlines()]

    def test_handshake_and_tools(self):
        replies = self.rpc([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                        "clientInfo": {"name": "t", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": {"name": "create_entry", "arguments": {"title": "x"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "bogus"},
        ], env={"LOGBOOK_SESSION_FILE": "/nonexistent/session"})
        self.assertEqual([r["id"] for r in replies], [1, 2, 3, 4])
        self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual([t["name"] for t in replies[1]["result"]["tools"]],
                         ["create_entry", "append_entry"])
        self.assertTrue(replies[2]["result"]["isError"])
        self.assertIn("session id unavailable", replies[2]["result"]["content"][0]["text"])
        self.assertEqual(replies[3]["error"]["code"], -32601)


if __name__ == "__main__":
    unittest.main()
