"""网关进程入口。

    python3 -m amr_gateway.main --config config/gateway.json

启动顺序建议（见架构文档 §14）：mosquitto → ROS bringup（含 rosbridge）→ 本进程。
网关必须是 /map 的第一个订阅者，否则 latched 话题可能被别人的 QoS 带偏。
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import signal
import threading

from . import config as gateway_config
from .http_api import GatewayContext, make_server
from .map_cache import MapCache
from .mqtt_bus import MqttBus
from .rosbridge_client import RosbridgeFeed
from .store import Store
from .tasks import TaskManager
from .ws_hub import WsHub


def _parse_args():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p = argparse.ArgumentParser(description="AMR 业务网关")
    p.add_argument("--config", default=os.path.join(here, "config", "gateway.json"))
    p.add_argument("--http-port", type=int, default=None)
    p.add_argument("--ws-port", type=int, default=None)
    p.add_argument("--data-dir", default=None)
    p.add_argument("--log-file", default=None)
    return p.parse_args()


def _setup_logging(log_file: str | None):
    handlers = [logging.StreamHandler()]
    if log_file:
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        handlers.append(logging.FileHandler(log_file, encoding="utf-8"))
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        handlers=handlers,
    )


def main():
    args = _parse_args()
    overrides = {}
    if args.http_port:
        overrides.setdefault("http", {})["port"] = args.http_port
    if args.ws_port:
        overrides.setdefault("ws", {})["port"] = args.ws_port
    if args.data_dir:
        overrides.setdefault("storage", {})["data_dir"] = args.data_dir
    cfg = gateway_config.load(args.config, overrides)
    os.makedirs(cfg.data_dir, exist_ok=True)
    _setup_logging(args.log_file)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    store = Store(cfg.db_path)
    hub = WsHub(loop, cfg.token)
    map_cache = MapCache(cfg.maps_dir)
    # 延迟绑定：tasks 需要 publish，mqtt 需要把回执交给 tasks
    holder: dict = {}

    def publish(topic, payload) -> bool:
        return holder["mqtt"].publish(topic, payload)

    def on_mqtt(topic, data):
        holder["tasks"].handle_mqtt(topic, data)

    tasks = TaskManager(store, cfg.policy, publish, hub)
    mqtt = MqttBus(cfg.mqtt, hub, on_mqtt)
    ros = RosbridgeFeed(cfg.rosbridge_url, map_cache, hub, cfg.policy)
    holder.update(tasks=tasks, mqtt=mqtt)

    ctx = GatewayContext(cfg, store, tasks, map_cache, ros, mqtt, hub)

    stop = asyncio.Event()

    def _shutdown(*_):
        loop.call_soon_threadsafe(stop.set)

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _shutdown)
        except NotImplementedError:  # Windows 下不支持，忽略
            pass

    async def ticker():
        while True:
            await asyncio.sleep(1.0)
            try:
                tasks.tick()
            except Exception:  # noqa: BLE001
                logging.getLogger("gateway.ticker").exception("tick 失败")

    async def amain():
        await hub.start(cfg.ws_host, cfg.ws_port)
        http_server = make_server(ctx)
        threading.Thread(target=http_server.serve_forever,
                         name="gateway-http", daemon=True).start()
        logging.getLogger("gateway").info(
            "HTTP http://%s:%d  WS ws://%s:%d/ws",
            cfg.http_host, cfg.http_port, cfg.ws_host, cfg.ws_port)

        mqtt.connect()
        ros_task = asyncio.create_task(ros.run())
        tick_task = asyncio.create_task(ticker())
        logging.getLogger("gateway").info("网关已启动，数据目录 %s", cfg.data_dir)

        await stop.wait()

        logging.getLogger("gateway").info("正在关闭…")
        ros.stop()
        ros_task.cancel()
        tick_task.cancel()
        http_server.shutdown()
        await hub.stop()
        mqtt.stop()
        await asyncio.gather(ros_task, tick_task, return_exceptions=True)

    try:
        loop.run_until_complete(amain())
    finally:
        store.close()
        loop.close()


if __name__ == "__main__":
    main()
