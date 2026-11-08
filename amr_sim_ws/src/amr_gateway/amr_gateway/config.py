"""网关配置：JSON 文件 + 命令行覆盖。

所有路径都相对“数据目录”（默认 ~/.amr_gateway），运行时数据不进 git。
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass


DEFAULT_CONFIG = {
    "http": {"host": "0.0.0.0", "port": 8080},
    "ws": {"host": "0.0.0.0", "port": 8081},
    "mqtt": {
        "host": "127.0.0.1",
        "port": 1884,
        "username": "gateway",
        # 仅限内网仿真；真机/公网部署必须换成动态令牌并加 TLS（见架构文档 §13）
        "password": "gateway-dev-pass",
        "client_id": "amr_gateway",
    },
    "rosbridge": {"url": "ws://127.0.0.1:9090"},
    "api": {"token": "amr-dev-token"},
    "storage": {"data_dir": "~/.amr_gateway"},
    "policy": {
        "ack_timeout_ms": 1500,
        "feedback_timeout_ms": 4000,
        "result_timeout_ms": 120000,
        "max_retries": 2,
        "default_ttl_ms": 8000,
        "lock_ttl_s": 60,
        "pose_min_interval_ms": 50,
        "scan_stride": 4,
    },
}


def _deep_merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


@dataclass
class Config:
    raw: dict

    @property
    def http_host(self) -> str:
        return self.raw["http"]["host"]

    @property
    def http_port(self) -> int:
        return int(self.raw["http"]["port"])

    @property
    def ws_host(self) -> str:
        return self.raw["ws"]["host"]

    @property
    def ws_port(self) -> int:
        return int(self.raw["ws"]["port"])

    @property
    def mqtt(self) -> dict:
        return self.raw["mqtt"]

    @property
    def rosbridge_url(self) -> str:
        return self.raw["rosbridge"]["url"]

    @property
    def token(self) -> str:
        return self.raw["api"]["token"]

    @property
    def data_dir(self) -> str:
        return os.path.abspath(os.path.expanduser(self.raw["storage"]["data_dir"]))

    @property
    def maps_dir(self) -> str:
        return os.path.join(self.data_dir, "maps")

    @property
    def db_path(self) -> str:
        return os.path.join(self.data_dir, "gateway.db")

    @property
    def policy(self) -> dict:
        return self.raw["policy"]


def load(path: str | None = None, overrides: dict | None = None) -> Config:
    """读取配置。文件不存在时用默认值，便于首次启动。"""
    raw = dict(DEFAULT_CONFIG)
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            raw = _deep_merge(raw, json.load(f))
    if overrides:
        raw = _deep_merge(raw, overrides)
    return Config(raw)
