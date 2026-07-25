#!/usr/bin/env python3
"""Dependency-free MCP mailbox for Codex/Claude Code coordination."""
from __future__ import annotations
import argparse, json, sqlite3, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROTOCOL_VERSION = "2025-06-18"
ROOT = Path(__file__).resolve().parents[2]

def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")

def default_db() -> Path:
    try:
        path = subprocess.check_output(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd=ROOT, text=True, stderr=subprocess.DEVNULL
        ).strip()
        return Path(path) / "agent-coordination.sqlite3"
    except (OSError, subprocess.CalledProcessError):
        return ROOT / ".coordination" / "agent-coordination.sqlite3"

class Mailbox:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=10)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
          CREATE TABLE IF NOT EXISTS messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT, sender TEXT NOT NULL,
            recipient TEXT NOT NULL, topic TEXT NOT NULL DEFAULT 'general',
            body TEXT NOT NULL, created_at TEXT NOT NULL, acknowledged_at TEXT);
          CREATE TABLE IF NOT EXISTS statuses(
            agent TEXT PRIMARY KEY, task TEXT NOT NULL, branch TEXT NOT NULL DEFAULT '',
            state TEXT NOT NULL, details TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS message_acks(
            message_id INTEGER NOT NULL, agent TEXT NOT NULL, acknowledged_at TEXT NOT NULL,
            PRIMARY KEY(message_id, agent),
            FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE);
        """)

    def send_message(self, a):
        cur = self.db.execute(
            "INSERT INTO messages(sender,recipient,topic,body,created_at) VALUES(?,?,?,?,?)",
            (a["sender"], a["recipient"], a.get("topic", "general"), a["body"], now()))
        self.db.commit()
        return {"message_id": cur.lastrowid, "delivered": True}

    def read_messages(self, a):
        query = """SELECT m.id,m.sender,m.recipient,m.topic,m.body,m.created_at,
                          a.acknowledged_at
                   FROM messages m LEFT JOIN message_acks a
                     ON a.message_id=m.id AND a.agent=?
                   WHERE (m.recipient=? OR m.recipient='all')"""
        params: list[Any] = [a["agent"], a["agent"]]
        if not a.get("include_acknowledged", False):
            query += " AND a.acknowledged_at IS NULL"
        if a.get("topic"):
            query += " AND m.topic=?"
            params.append(a["topic"])
        query += " ORDER BY m.id ASC LIMIT ?"
        params.append(a.get("limit", 50))
        return {"messages": [dict(row) for row in self.db.execute(query, params)]}

    def acknowledge_messages(self, a):
        ids = a["message_ids"]
        marks = ",".join("?" for _ in ids)
        eligible = self.db.execute(
            f"SELECT id FROM messages WHERE id IN ({marks}) "
            "AND (recipient=? OR recipient='all')", [*ids, a["agent"]]).fetchall()
        before = self.db.total_changes
        self.db.executemany(
            "INSERT OR IGNORE INTO message_acks(message_id,agent,acknowledged_at) VALUES(?,?,?)",
            [(row["id"], a["agent"], now()) for row in eligible])
        self.db.commit()
        return {"acknowledged": self.db.total_changes - before}

    def set_status(self, a):
        self.db.execute("""INSERT INTO statuses(agent,task,branch,state,details,updated_at)
          VALUES(?,?,?,?,?,?) ON CONFLICT(agent) DO UPDATE SET task=excluded.task,
          branch=excluded.branch,state=excluded.state,details=excluded.details,
          updated_at=excluded.updated_at""",
          (a["agent"], a["task"], a.get("branch", ""), a["state"],
           a.get("details", ""), now()))
        self.db.commit()
        return {"updated": True}

    def get_status(self, _a):
        rows = self.db.execute(
            "SELECT agent,task,branch,state,details,updated_at FROM statuses ORDER BY agent")
        return {"agents": [dict(row) for row in rows]}

def schema(properties, required=()):
    return {"type": "object", "properties": properties, "required": list(required),
            "additionalProperties": False}

agent = {"type": "string", "enum": ["codex", "claude"]}
TOOLS = [
  {"name":"send_message","description":"Send a message to codex, claude, or all.",
   "inputSchema":schema({"sender":agent,"recipient":{"type":"string","enum":["codex","claude","all"]},
                         "topic":{"type":"string","default":"general"},"body":{"type":"string"}},
                        ["sender","recipient","body"])},
  {"name":"read_messages","description":"Read messages addressed to an agent.",
   "inputSchema":schema({"agent":agent,"topic":{"type":"string"},
                         "limit":{"type":"integer","minimum":1,"maximum":200,"default":50},
                         "include_acknowledged":{"type":"boolean","default":False}},["agent"])},
  {"name":"acknowledge_messages","description":"Mark handled messages as acknowledged.",
   "inputSchema":schema({"agent":agent,"message_ids":{"type":"array","items":{"type":"integer"},
                         "minItems":1,"uniqueItems":True}},["agent","message_ids"])},
  {"name":"set_status","description":"Publish task and branch to prevent conflicting work.",
   "inputSchema":schema({"agent":agent,"task":{"type":"string"},"branch":{"type":"string"},
                         "state":{"type":"string","enum":["planning","working","blocked","review","done","idle"]},
                         "details":{"type":"string"}},["agent","task","state"])},
  {"name":"get_status","description":"List the latest state of both agents.",
   "inputSchema":schema({})},
]

def tool_result(value):
    return {"content":[{"type":"text","text":json.dumps(value,indent=2)}],
            "structuredContent":value}

def handle(box: Mailbox, req):
    if "id" not in req:
        return None
    rid, method = req["id"], req.get("method")
    try:
        if method == "initialize":
            payload = {"protocolVersion":PROTOCOL_VERSION,
                       "capabilities":{"tools":{"listChanged":False}},
                       "serverInfo":{"name":"clua-agent-coordination","version":"1.0.0"}}
        elif method == "ping":
            payload = {}
        elif method == "tools/list":
            payload = {"tools":TOOLS}
        elif method == "tools/call":
            p = req.get("params", {})
            handlers = {name:getattr(box,name) for name in
                        ("send_message","read_messages","acknowledge_messages","set_status","get_status")}
            if p.get("name") not in handlers:
                raise ValueError(f"Unknown tool: {p.get('name')}")
            payload = tool_result(handlers[p["name"]](p.get("arguments", {})))
        else:
            return {"jsonrpc":"2.0","id":rid,
                    "error":{"code":-32601,"message":f"Method not found: {method}"}}
        return {"jsonrpc":"2.0","id":rid,"result":payload}
    except (KeyError, TypeError, ValueError, sqlite3.Error) as exc:
        return {"jsonrpc":"2.0","id":rid,"error":{"code":-32602,"message":str(exc)}}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=default_db())
    args = parser.parse_args()
    box = Mailbox(args.db.resolve())
    for line in sys.stdin:
        try:
            response = handle(box, json.loads(line))
        except json.JSONDecodeError as exc:
            response = {"jsonrpc":"2.0","id":None,"error":{"code":-32700,"message":str(exc)}}
        if response is not None:
            print(json.dumps(response,separators=(",",":")),flush=True)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
