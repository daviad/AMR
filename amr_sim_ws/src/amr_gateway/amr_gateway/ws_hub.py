"""WebSocket 推送中心（websockets 服务端）。

设计：
- 每个客户端维护一个订阅集合（默认全量）；
- HTTP/MQTT/rosbridge 线程都通过 broadcast() 发送，内部用 loop.call_soon_threadsafe
  切回 asyncio 线程，避免跨线程写 socket；
- 客户端断开只移除连接，不做消息回放（状态对齐由 GET /tasks 负责）。
"""
from __future__ import annotations

import asyncio
import json
import logging
from urllib.parse import parse_qs, urlparse

import websockets

log = logging.getLogger("gateway.ws")

ALL_TOPICS = (
    "pose", "plan", "scan", "task", "battery", "mode", "inspection",
    "alert", "lock", "map_meta", "degraded",
)


class WsHub:
    def __init__(self, loop: asyncio.AbstractEventLoop, token: str):
        self._loop = loop
        self._token = token
        self._clients: dict[object, set[str]] = {}
        self._server = None

    async def start(self, host: str, port: int):
        self._server = await websockets.serve(
            self._handle, host, port, ping_interval=20, ping_timeout=20,
            max_size=2 ** 20,
        )
        log.info("WebSocket 监听 ws://%s:%d/ws", host, port)

    async def stop(self):
        if self._server:
            self._server.close()
            await self._server.wait_closed()

    # ── 连接处理 ──
    async def _handle(self, websocket):
        path = getattr(websocket, "request", None)
        raw_path = path.path if path is not None else "/ws"
        query = parse_qs(urlparse(raw_path).query)
        if self._token and query.get("token", [""])[0] != self._token:
            await websocket.close(code=4401, reason="unauthorized")
            return
        self._clients[websocket] = set(ALL_TOPICS)
        log.info("WS 客户端接入（当前 %d）", len(self._clients))
        try:
            await websocket.send(json.dumps({
                "type": "hello", "gateway": "0.1.0",
                "ts": _now_ms(), "topics": list(ALL_TOPICS),
            }))
            async for raw in websocket:
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                op = msg.get("op")
                if op == "ping":
                    await websocket.send(json.dumps(
                        {"type": "pong", "ts": _now_ms()}))
                elif op == "subscribe":
                    topics = msg.get("topics")
                    if isinstance(topics, list):
                        self._clients[websocket] = {
                            t for t in topics if t in ALL_TOPICS}
                        await websocket.send(json.dumps(
                            {"type": "subscribed",
                             "topics": sorted(self._clients[websocket])}))
        except websockets.ConnectionClosed:
            pass
        finally:
            self._clients.pop(websocket, None)
            log.info("WS 客户端断开（剩余 %d）", len(self._clients))

    # ── 广播 ──
    def broadcast(self, topic: str, payload: dict):
        """线程安全：可从任意线程调用。"""
        if not self._loop.is_running():
            return
        self._loop.call_soon_threadsafe(
            lambda: self._loop.create_task(self._broadcast(topic, payload)))

    async def _broadcast(self, topic: str, payload: dict):
        payload.setdefault("type", topic)
        raw = json.dumps(payload, ensure_ascii=False)
        stale = []
        for ws, topics in list(self._clients.items()):
            if topic not in topics and "*" not in topics:
                continue
            try:
                await ws.send(raw)
            except websockets.ConnectionClosed:
                stale.append(ws)
            except Exception:  # noqa: BLE001 - 单个客户端异常不影响其他人
                stale.append(ws)
        for ws in stale:
            self._clients.pop(ws, None)

    def client_count(self) -> int:
        return len(self._clients)


def _now_ms() -> int:
    import time
    return int(time.time() * 1000)
