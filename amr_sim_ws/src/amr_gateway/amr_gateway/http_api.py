"""HTTP 业务 API（标准库 ThreadingHTTPServer，零额外依赖）。

Base：http://<host>:8080
鉴权：Authorization: Bearer <token>（/healthz 与 /auth/login 除外）
契约见 docs/架构-网关收口.md §5。Web 端需要 CORS，这里对所有响应加头。
"""
from __future__ import annotations

import json
import logging
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .tasks import ApiError

log = logging.getLogger("gateway.http")

START_TS = time.time()


class GatewayContext:
    """把 handler 需要的依赖集中起来，避免全局变量。"""

    def __init__(self, cfg, store, tasks, map_cache, ros, mqtt, hub):
        self.cfg = cfg
        self.store = store
        self.tasks = tasks
        self.map_cache = map_cache
        self.ros = ros
        self.mqtt = mqtt
        self.hub = hub


def make_server(ctx: GatewayContext) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "amr-gateway/0.1"

        # ── 基础响应 ──
        def _cors(self):
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers",
                             "Content-Type, Authorization")
            self.send_header("Access-Control-Allow-Methods",
                             "GET, POST, DELETE, OPTIONS")

        def _json(self, status: int, obj: dict):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self._cors()
            self.end_headers()
            self.wfile.write(body)

        def _err(self, status: int, code: str, message: str):
            self._json(status, {"error": {"code": code, "message": message}})

        def _body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0:
                return {}
            if length > 2 * 1024 * 1024:
                raise ApiError(400, "INVALID_ARGUMENT", "请求体过大")
            raw = self.rfile.read(length)
            try:
                data = json.loads(raw.decode("utf-8") or "{}")
            except (ValueError, UnicodeDecodeError):
                raise ApiError(400, "INVALID_ARGUMENT", "JSON 解析失败")
            if not isinstance(data, dict):
                raise ApiError(400, "INVALID_ARGUMENT", "JSON 必须是对象")
            return data

        def _authed(self, query: dict) -> bool:
            token = ctx.cfg.token
            header = self.headers.get("Authorization") or ""
            if header.startswith("Bearer ") and header[7:] == token:
                return True
            # 浏览器 <img> / WS 无法带请求头，允许 query 兜底
            return query.get("token", [""])[0] == token

        def _guard(self, query) -> bool:
            if not self._authed(query):
                self._err(401, "UNAUTHORIZED", "缺少或错误的 token")
                return False
            return True

        # ── 路由 ──
        def do_OPTIONS(self):  # noqa: N802
            self.send_response(204)
            self._cors()
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):  # noqa: N802
            self._route("GET")

        def do_POST(self):  # noqa: N802
            self._route("POST")

        def do_DELETE(self):  # noqa: N802
            self._route("DELETE")

        def _route(self, method: str):
            parsed = urlparse(self.path)
            path = parsed.path
            query = parse_qs(parsed.query)
            try:
                if path == "/healthz" and method == "GET":
                    return self._healthz()
                if path == "/api/v1/auth/login" and method == "POST":
                    body = self._body()
                    return self._json(200, {
                        "token": ctx.cfg.token,
                        "expires_at": None,
                        "device_id": body.get("device_id"),
                    })
                if not self._guard(query):
                    return

                if path == "/api/v1/map/meta" and method == "GET":
                    return self._map_meta()
                if path == "/api/v1/map/pgm" and method == "GET":
                    return self._map_pgm(query)
                if path == "/api/v1/tasks":
                    if method == "POST":
                        return self._create_task()
                    if method == "GET":
                        return self._list_tasks(query)
                if path.startswith("/api/v1/tasks/"):
                    parts = path.strip("/").split("/")
                    # api v1 tasks <cmd_id> [action]
                    if len(parts) >= 4:
                        cmd_id = parts[3]
                        action = parts[4] if len(parts) > 4 else None
                        if action is None and method == "GET":
                            return self._json(200, ctx.tasks.get_task(cmd_id))
                        if action == "cancel" and method == "POST":
                            body = self._body()
                            return self._json(202, ctx.tasks.cancel(
                                cmd_id, body.get("holder", "")))
                        if action == "retry" and method == "POST":
                            body = self._body()
                            return self._json(202, ctx.tasks.retry(
                                cmd_id, body.get("holder", "")))
                if path == "/api/v1/commands" and method == "POST":
                    body = self._body()
                    return self._json(202, ctx.tasks.command(
                        str(body.get("name") or ""),
                        body.get("payload") or {},
                        body.get("holder", ""),
                    ))
                if path == "/api/v1/lock":
                    if method == "GET":
                        return self._json(200, ctx.tasks.lock_view())
                    if method == "POST":
                        body = self._body()
                        return self._json(200, ctx.tasks.acquire_lock(
                            body.get("holder", ""), body.get("ttl_s")))
                    if method == "DELETE":
                        holder = query.get("holder", [""])[0]
                        ctx.tasks.release_lock(holder)
                        return self._json(204, {})
                if path == "/api/v1/snapshot" and method == "GET":
                    return self._snapshot()

                return self._err(404, "NOT_FOUND", f"未知路径 {method} {path}")
            except ApiError as e:
                return self._err(e.status, e.code, e.message)
            except BrokenPipeError:
                pass
            except Exception as e:  # noqa: BLE001
                log.exception("HTTP 处理异常")
                return self._err(500, "INTERNAL", str(e))

        # ── 具体处理 ──
        def _healthz(self):
            active = ctx.store.active_task()
            meta = ctx.map_cache.meta()
            self._json(200, {
                "ok": True,
                "uptime_s": round(time.time() - START_TS, 1),
                "mqtt": ctx.mqtt.connected,
                "rosbridge": ctx.ros.connected,
                "ws_clients": ctx.hub.client_count(),
                "map_version": meta["version"] if meta else None,
                "active_task": ({
                    "cmd_id": active["cmd_id"], "phase": active["phase"]
                } if active else None),
            })

        def _map_meta(self):
            meta = ctx.map_cache.meta()
            if not meta:
                return self._err(404, "MAP_NOT_READY", "尚未收到 /map")
            body = dict(meta)
            body["pgm_url"] = f"/api/v1/map/pgm?version={meta['version']}"
            self._json(200, body)

        def _map_pgm(self, query):
            version = query.get("version", [None])[0]
            meta = ctx.map_cache.meta()
            if not meta:
                return self._err(404, "MAP_NOT_READY", "尚未收到 /map")
            pgm = ctx.map_cache.pgm(version)
            if pgm is None:
                return self._err(409, "MAP_VERSION_MISMATCH",
                                 f"版本 {version} 已过期，请重新取 meta")
            self.send_response(200)
            self.send_header("Content-Type", "image/x-portable-graymap")
            self.send_header("Content-Length", str(len(pgm)))
            self.send_header("X-Map-Version", meta["version"])
            self._cors()
            self.end_headers()
            self.wfile.write(pgm)

        def _create_task(self):
            body = self._body()
            if str(body.get("type") or "navigate") != "navigate":
                return self._err(400, "INVALID_ARGUMENT", "仅支持 type=navigate")
            try:
                x = float(body["x"])
                y = float(body["y"])
                theta = float(body.get("theta", 0.0))
            except (KeyError, TypeError, ValueError):
                return self._err(422, "BAD_PAYLOAD", "缺少 x/y 或不是数值")
            holder = str(body.get("holder") or "")
            task = ctx.tasks.create_navigate(
                x, y, theta, holder,
                ttl_ms=body.get("ttl_ms"),
            )
            self._json(202, {
                "cmd_id": task["cmd_id"], "trace_id": task["trace_id"],
                "phase": task["phase"], "created_at": task["created_at"],
                "task": task,
            })

        def _list_tasks(self, query):
            limit = int(query.get("limit", ["20"])[0])
            limit = max(1, min(100, limit))
            phase = query.get("phase", [None])[0]
            self._json(200, {"tasks": ctx.tasks.list_tasks(limit, phase)})

        def _snapshot(self):
            jpeg = ctx.ros.snapshot_jpeg()
            if not jpeg:
                return self._err(503, "NO_FRAME", "还没有图像帧")
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(jpeg)))
            self.send_header("Cache-Control", "no-store")
            self._cors()
            self.end_headers()
            self.wfile.write(jpeg)

        def log_message(self, fmt, *args):
            log.debug("%s - %s", self.address_string(), fmt % args)

    server = ThreadingHTTPServer((ctx.cfg.http_host, ctx.cfg.http_port), Handler)
    server.daemon_threads = True
    return server
