"""MQTT 总线：paho-mqtt 客户端（网关是 amr/cmd/# 的唯一发布者）。

- 上行回执 amr/cmd/ack|feedback|result 与状态 amr/status/# 转交任务管理器/WS；
- 断线自动重连（paho loop_start + reconnect_delay）；
- 未连接时 publish 直接返回 False，HTTP 层据此返回 503 MQTT_UNAVAILABLE。
"""
from __future__ import annotations

import json
import logging
import time

try:
    import paho.mqtt.client as mqtt
except ImportError:  # 允许在没有依赖时启动（仅降级，不阻塞其它模块）
    mqtt = None

log = logging.getLogger("gateway.mqtt")

MQTT_ERR_SUCCESS = 0

CMD_TOPICS = {
    "mode": "amr/cmd/mode",
    "estop": "amr/cmd/estop",
    "return_charge": "amr/cmd/return_charge",
    "inspection_start": "amr/cmd/inspection/start",
    "inspection_stop": "amr/cmd/inspection/stop",
}

STATUS_TOPIC_TO_TYPE = {
    "amr/status/battery": "battery",
    "amr/status/mode": "mode",
    "amr/status/inspection": "inspection",
    "amr/status/video": "video",
    "amr/status/video_metrics": "video_metrics",
    "amr/alert": "alert",
}


class MqttBus:
    def __init__(self, cfg: dict, hub, on_feedback):
        self._cfg = cfg
        self._hub = hub
        self._on_feedback = on_feedback
        self._connected = False
        self._client = None

    @property
    def connected(self) -> bool:
        return self._connected

    def connect(self) -> bool:
        if mqtt is None:
            log.error("未安装 paho-mqtt，MQTT 通道不可用（pip install -r requirements.txt）")
            return False
        client_id = self._cfg.get("client_id", "amr_gateway")
        client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=client_id,
            protocol=mqtt.MQTTv311,
        )
        client.username_pw_set(self._cfg.get("username", ""),
                               self._cfg.get("password", ""))
        client.on_connect = self._on_connect
        client.on_disconnect = self._on_disconnect
        client.on_message = self._on_message
        client.reconnect_delay_set(min_delay=1, max_delay=15)
        self._client = client
        client.connect_async(self._cfg.get("host", "127.0.0.1"),
                             int(self._cfg.get("port", 1884)), keepalive=30)
        client.loop_start()
        return True

    def stop(self):
        if self._client:
            try:
                self._client.loop_stop()
                self._client.disconnect()
            except Exception:  # noqa: BLE001
                pass

    # ── paho 回调（paho 自己的线程）──
    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        if reason_code == 0:
            self._connected = True
            log.info("MQTT 已连接 %s:%s",
                     self._cfg.get("host"), self._cfg.get("port"))
            client.subscribe([
                ("amr/cmd/ack", 1),
                ("amr/cmd/feedback", 0),
                ("amr/cmd/result", 1),
                ("amr/status/#", 0),
                ("amr/alert", 0),
            ])
            self._hub.broadcast("degraded", {
                "component": "mqtt", "up": True, "detail": "mqtt connected"})
        else:
            log.error("MQTT 连接被拒：%s（检查 ACL/账号）", reason_code)

    def _on_disconnect(self, client, userdata, flags, reason_code, properties=None):
        if self._connected:
            log.warning("MQTT 断开：%s", reason_code)
        self._connected = False
        self._hub.broadcast("degraded", {
            "component": "mqtt", "up": False, "detail": str(reason_code)})

    def _on_message(self, client, userdata, msg):
        try:
            data = json.loads(msg.payload.decode("utf-8") or "{}")
            if not isinstance(data, dict):
                return
        except (ValueError, UnicodeDecodeError):
            return
        topic = msg.topic
        if topic in ("amr/cmd/ack", "amr/cmd/feedback", "amr/cmd/result"):
            self._on_feedback(topic, data)
            return
        status_type = STATUS_TOPIC_TO_TYPE.get(topic)
        if status_type:
            self._hub.broadcast(status_type, {"data": data, "stamp_ms": _now_ms()})

    # ── 发布 ──
    def publish(self, topic: str, payload: dict) -> bool:
        if not self._connected or self._client is None:
            return False
        try:
            info = self._client.publish(
                topic, json.dumps(payload, ensure_ascii=False),
                qos=1, retain=False)
            return info.rc == MQTT_ERR_SUCCESS
        except Exception:  # noqa: BLE001
            return False


def _now_ms() -> int:
    return int(time.time() * 1000)
