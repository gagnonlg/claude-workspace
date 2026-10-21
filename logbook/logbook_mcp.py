#!/usr/bin/env python3
"""Logbook MCP server (stdio), running inside the container.

Exposes `create_entry` and `append_entry`, which forward to the host-side
logbook-bridge. Each Claude Code session gets one logbook entry: the session
id is written by the SessionStart hook (logbook-session-hook) and the
session -> entry mapping persists across restarts, so `--resume` continues
the same entry while `/clear` starts a new one.

Implements the small subset of MCP needed for tools, using only the stdlib.
"""

import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

SESSION_FILE = os.environ.get("LOGBOOK_SESSION_FILE", "/tmp/claude-logbook/session")
STATE_FILE = os.environ.get("LOGBOOK_STATE_FILE",
                            os.path.expanduser("~/.claude/logbook-sessions.json"))
SUPPORTED_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")

TOOLS = [
    {
        "name": "create_entry",
        "description": (
            "Create this session's entry in the user's org-roam logbook and return its id. "
            "Each Claude session has exactly one logbook entry: calling this again in the "
            "same session returns the existing id instead of creating a new one."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"title": {"type": "string", "description": "Title of the logbook entry."}},
            "required": ["title"],
        },
    },
    {
        "name": "append_entry",
        "description": (
            "Append a timestamped section to this session's logbook entry. `title` becomes the "
            "section heading; `text` is the body in org-mode syntax (not Markdown). Headings in "
            "`text` start at `*` and are nested under the section automatically."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "The id returned by create_entry."},
                "title": {"type": "string", "description": "Heading for this section."},
                "text": {"type": "string", "description": "Org-mode body text."},
            },
            "required": ["id", "title", "text"],
        },
    },
]


class ToolError(Exception):
    pass


def current_session():
    try:
        with open(SESSION_FILE) as f:
            session = f.read().strip()
    except OSError:
        session = ""
    if not session:
        raise ToolError("Claude session id unavailable (the logbook SessionStart hook has not run)")
    return session


def load_state():
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
        return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state):
    directory = os.path.dirname(STATE_FILE) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, STATE_FILE)


def call_bridge(endpoint, payload):
    url = os.environ.get("LOGBOOK_URL", "")
    token = os.environ.get("LOGBOOK_TOKEN", "")
    if not url or not token:
        raise ToolError("logbook is not configured (LOGBOOK_URL / LOGBOOK_TOKEN unset; start via ./run)")
    request = urllib.request.Request(
        url.rstrip("/") + endpoint,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            reply = json.load(response)
    except urllib.error.HTTPError as e:
        try:
            reply = json.load(e)
        except ValueError:
            raise ToolError("logbook bridge returned HTTP %d" % e.code)
    except (urllib.error.URLError, OSError) as e:
        raise ToolError("cannot reach the logbook bridge at %s: %s" % (url, e))
    if not reply.get("ok"):
        raise ToolError("logbook error: %s" % reply.get("error", "unknown"))
    return reply["id"]


def create_entry(title):
    session = current_session()
    state = load_state()
    if session in state:
        return "This session's logbook entry already exists; its id is %s" % state[session]
    entry_id = call_bridge("/create", {"title": title})
    state[session] = entry_id
    save_state(state)
    return entry_id


def append_entry(entry_id, title, text):
    expected = load_state().get(current_session())
    if expected is None:
        raise ToolError("this session has no logbook entry yet; call create_entry first")
    if entry_id != expected:
        raise ToolError("id %s is not this session's logbook entry (%s)" % (entry_id, expected))
    call_bridge("/append", {"id": entry_id, "title": title, "text": text})
    return "Appended to logbook entry %s" % entry_id


def call_tool(name, arguments):
    def arg(key):
        value = arguments.get(key)
        if not isinstance(value, str):
            raise ToolError("argument %r must be a string" % key)
        return value

    if name == "create_entry":
        return create_entry(arg("title"))
    if name == "append_entry":
        return append_entry(arg("id"), arg("title"), arg("text"))
    raise ToolError("unknown tool %r" % name)


def handle(message):
    """Return the JSON-RPC response for MESSAGE, or None for notifications."""
    method = message.get("method")
    if "id" not in message:
        return None
    params = message.get("params") or {}
    if method == "initialize":
        requested = params.get("protocolVersion")
        result = {
            "protocolVersion": requested if requested in SUPPORTED_VERSIONS else SUPPORTED_VERSIONS[0],
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "logbook", "version": "1.0.0"},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        try:
            text, is_error = call_tool(params.get("name"), params.get("arguments") or {}), False
        except ToolError as e:
            text, is_error = str(e), True
        result = {"content": [{"type": "text", "text": text}], "isError": is_error}
    else:
        return {"jsonrpc": "2.0", "id": message["id"],
                "error": {"code": -32601, "message": "method not found: %s" % method}}
    return {"jsonrpc": "2.0", "id": message["id"], "result": result}


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except ValueError:
            response = {"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "parse error"}}
        else:
            response = handle(message) if isinstance(message, dict) else None
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
