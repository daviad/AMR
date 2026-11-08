"""SQLite 存储：任务表 + 审计表 + 控制锁（单行）。

HTTP 线程与 asyncio 线程都会调用，所以统一用一把 threading.Lock 包住写操作；
WAL 模式让读不阻塞写。事务都很短，单设备场景足够。
"""
from __future__ import annotations

import json
import os
import sqlite3
import threading
import time


SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks(
  cmd_id TEXT PRIMARY KEY,
  trace_id TEXT,
  type TEXT,
  payload_json TEXT,
  phase TEXT,
  created_at INTEGER,
  updated_at INTEGER,
  ttl_ms INTEGER DEFAULT 8000,
  retry_count INTEGER DEFAULT 0,
  error_code TEXT,
  error_msg TEXT,
  result_json TEXT
);
CREATE TABLE IF NOT EXISTS audit(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER,
  actor TEXT,
  action TEXT,
  cmd_id TEXT,
  detail_json TEXT
);
CREATE TABLE IF NOT EXISTS device_lock(
  id INTEGER PRIMARY KEY CHECK (id = 1),
  holder TEXT,
  expires_at INTEGER,
  updated_at INTEGER
);
"""


def now_ms() -> int:
    return int(time.time() * 1000)


class Store:
    def __init__(self, path: str):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.executescript(SCHEMA)
            self._conn.commit()

    # ── 任务 ──
    def create_task(self, cmd_id, trace_id, type_, payload, phase, ttl_ms):
        ts = now_ms()
        with self._lock:
            self._conn.execute(
                "INSERT INTO tasks(cmd_id,trace_id,type,payload_json,phase,"
                "created_at,updated_at,ttl_ms,retry_count) VALUES(?,?,?,?,?,?,?,?,0)",
                (cmd_id, trace_id, type_, json.dumps(payload, ensure_ascii=False),
                 phase, ts, ts, ttl_ms),
            )
            self._conn.commit()
        return self.get_task(cmd_id)

    def update_task(self, cmd_id, **fields):
        if not fields:
            return
        fields["updated_at"] = now_ms()
        cols = ", ".join(f"{k}=?" for k in fields)
        with self._lock:
            self._conn.execute(f"UPDATE tasks SET {cols} WHERE cmd_id=?",
                               (*fields.values(), cmd_id))
            self._conn.commit()
        return self.get_task(cmd_id)

    def get_task(self, cmd_id) -> dict | None:
        with self._lock:
            row = self._conn.execute("SELECT * FROM tasks WHERE cmd_id=?",
                                     (cmd_id,)).fetchone()
        return self._row_to_task(row) if row else None

    def list_tasks(self, limit=20, phase=None) -> list[dict]:
        sql = "SELECT * FROM tasks"
        args: list = []
        if phase:
            sql += " WHERE phase=?"
            args.append(phase)
        sql += " ORDER BY created_at DESC LIMIT ?"
        args.append(int(limit))
        with self._lock:
            rows = self._conn.execute(sql, args).fetchall()
        return [self._row_to_task(r) for r in rows]

    def active_task(self) -> dict | None:
        # 终态集合：SUCCEEDED / FAILED / CANCELLED / TIMEOUT / EXPIRED
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM tasks WHERE phase NOT IN "
                "('SUCCEEDED','FAILED','CANCELLED','TIMEOUT','EXPIRED') "
                "ORDER BY created_at DESC LIMIT 1").fetchone()
        return self._row_to_task(row) if row else None

    @staticmethod
    def _row_to_task(row) -> dict:
        d = dict(row)
        d["payload"] = json.loads(d.pop("payload_json") or "{}")
        raw_result = d.pop("result_json", None)
        d["result"] = json.loads(raw_result) if raw_result else None
        return d

    # ── 审计 ──
    def audit(self, actor, action, cmd_id=None, detail=None):
        with self._lock:
            self._conn.execute(
                "INSERT INTO audit(ts,actor,action,cmd_id,detail_json) VALUES(?,?,?,?,?)",
                (now_ms(), actor, action, cmd_id,
                 json.dumps(detail or {}, ensure_ascii=False)),
            )
            self._conn.commit()

    def recent_audit(self, limit=50) -> list[dict]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM audit ORDER BY id DESC LIMIT ?", (int(limit),)).fetchall()
        return [dict(r) for r in rows]

    # ── 控制锁 ──
    def get_lock(self) -> dict | None:
        with self._lock:
            row = self._conn.execute("SELECT * FROM device_lock WHERE id=1").fetchone()
        return dict(row) if row else None

    def set_lock(self, holder, expires_at):
        with self._lock:
            self._conn.execute(
                "INSERT INTO device_lock(id,holder,expires_at,updated_at) VALUES(1,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET holder=excluded.holder, "
                "expires_at=excluded.expires_at, updated_at=excluded.updated_at",
                (holder, expires_at, now_ms()),
            )
            self._conn.commit()

    def clear_lock(self):
        with self._lock:
            self._conn.execute("DELETE FROM device_lock WHERE id=1")
            self._conn.commit()

    def close(self):
        with self._lock:
            self._conn.close()
