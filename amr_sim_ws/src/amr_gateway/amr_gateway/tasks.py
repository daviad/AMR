"""任务状态机 + 控制锁 + 审计（网关侧唯一权威）。

状态迁移（详见 docs/架构-网关收口.md §8）：
  CREATED → PUBLISHED → ACCEPTED → EXECUTING → SUCCEEDED
  异常：PUBLISHED --ack 超时→ UNKNOWN --重发(≤max, 重打时间戳)→ PUBLISHED
        ACCEPTED/EXECUTING --feedback 超时→ STALE（非终态，迟到 feedback 可恢复）
        ACCEPTED/EXECUTING/STALE + cancel → CANCEL_REQUESTED → CANCELLED
        任意非终态 --result 超时→ TIMEOUT（迟到 result 仍回填）
"""
from __future__ import annotations

import json
import logging
import time
import uuid

log = logging.getLogger("gateway.tasks")

TERMINAL = {"SUCCEEDED", "FAILED", "CANCELLED", "TIMEOUT", "EXPIRED"}
# 这些相位下用户点击“重发”才有意义
RETRYABLE = {"PUBLISHED", "ACCEPTED", "EXECUTING", "STALE", "UNKNOWN"}


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def _new_id(prefix: str) -> str:
    return f"{prefix}-{uuid.uuid4().hex}"


def _now_ms() -> int:
    return int(time.time() * 1000)


class TaskManager:
    def __init__(self, store, policy: dict, publish, hub):
        self._store = store
        self._policy = policy
        self._publish = publish          # callable(topic, payload) -> bool
        self._hub = hub
        self._lock_ttl_s = int(policy.get("lock_ttl_s", 60))

    # ───────────────── 控制锁 ─────────────────
    def lock_view(self) -> dict:
        lock = self._store.get_lock()
        now = _now_ms()
        if not lock or (lock.get("expires_at") or 0) <= now:
            return {"holder": None, "expires_at": None}
        return {"holder": lock["holder"], "expires_at": lock["expires_at"]}

    def acquire_lock(self, holder: str, ttl_s: int | None = None) -> dict:
        if not holder:
            raise ApiError(400, "INVALID_ARGUMENT", "holder 不能为空")
        ttl = int(ttl_s or self._lock_ttl_s)
        lock = self._store.get_lock()
        now = _now_ms()
        expires = now + ttl * 1000
        if lock and lock.get("holder") and lock["holder"] != holder \
                and (lock.get("expires_at") or 0) > now:
            self._store.audit(holder, "lock_denied", None,
                              {"current_holder": lock["holder"]})
            raise ApiError(409, "LOCKED",
                           f"设备正被 {lock['holder']} 控制（{int((lock['expires_at'] - now) / 1000)}s 后过期）")
        self._store.set_lock(holder, expires)
        self._store.audit(holder, "lock_acquired", None, {"ttl_s": ttl})
        view = {"holder": holder, "expires_at": expires}
        self._hub.broadcast("lock", view)
        return view

    def release_lock(self, holder: str):
        lock = self._store.get_lock()
        if not lock or not lock.get("holder"):
            return
        if lock["holder"] != holder:
            raise ApiError(409, "LOCKED", f"锁由 {lock['holder']} 持有，不能代释放")
        self._store.clear_lock()
        self._store.audit(holder, "lock_released")
        self._hub.broadcast("lock", {"holder": None, "expires_at": None})

    def _ensure_lock(self, holder: str):
        """没有锁时自动把当前操作者设为持有者；被他人持有则拒绝。"""
        lock = self._store.get_lock()
        now = _now_ms()
        if not lock or not lock.get("holder") or (lock.get("expires_at") or 0) <= now:
            self._store.set_lock(holder, now + self._lock_ttl_s * 1000)
            self._store.audit(holder, "lock_auto_acquired")
            self._hub.broadcast("lock", {
                "holder": holder,
                "expires_at": now + self._lock_ttl_s * 1000})
            return
        if lock["holder"] != holder:
            raise ApiError(409, "LOCKED", f"设备正被 {lock['holder']} 控制")
        # 同一持有者每次操作顺带续租
        self._store.set_lock(holder, now + self._lock_ttl_s * 1000)

    def _check_holder(self, holder: str):
        if not holder:
            raise ApiError(400, "INVALID_ARGUMENT", "holder 不能为空")
        self._ensure_lock(holder)

    # ───────────────── 导航任务 ─────────────────
    def create_navigate(self, x, y, theta, holder, ttl_ms=None) -> dict:
        self._check_holder(holder)
        active = self._store.active_task()
        if active:
            raise ApiError(409, "TASK_ACTIVE",
                           f"已有活动任务 {active['cmd_id']}（{active['phase']}）")
        ttl = int(ttl_ms or self._policy.get("default_ttl_ms", 8000))
        cmd_id = _new_id("cmd")
        trace_id = _new_id("trace")
        self._store.create_task(
            cmd_id, trace_id, "navigate",
            {"x": x, "y": y, "theta": theta}, "CREATED", ttl)
        self._store.audit(holder, "task_create", cmd_id,
                          {"x": x, "y": y, "theta": theta})
        ok = self._publish_goal(cmd_id)
        task = self._store.get_task(cmd_id)
        if not ok:
            task = self._store.update_task(
                cmd_id, phase="FAILED", error_code="MQTT_UNAVAILABLE",
                error_msg="MQTT 未连接，指令未发出")
            self._emit(task, "state")
            raise ApiError(503, "MQTT_UNAVAILABLE", "MQTT 未连接，指令未发出")
        self._emit(task, "publish")
        return self._view(task)

    def _publish_goal(self, cmd_id: str) -> bool:
        """发布/重发导航目标。时间戳每次重新生成——这是重试不再被判 EXPIRED 的关键。"""
        task = self._store.get_task(cmd_id)
        if not task:
            return False
        cmd = {
            "cmd_id": task["cmd_id"],
            "trace_id": task["trace_id"],
            "timestamp_ms": _now_ms(),       # 必须用现在，不能用客户端旧值
            "ttl_ms": task["ttl_ms"],
            "payload": task["payload"],
        }
        ok = self._publish("amr/cmd/goal", cmd)
        if ok:
            self._store.update_task(cmd_id, phase="PUBLISHED",
                                    error_code=None, error_msg=None)
        return ok

    def retry(self, cmd_id: str, holder: str) -> dict:
        self._check_holder(holder)
        task = self._store.get_task(cmd_id)
        if not task:
            raise ApiError(404, "NOT_FOUND", f"任务 {cmd_id} 不存在")
        if task["phase"] in TERMINAL:
            raise ApiError(409, "TASK_TERMINAL",
                           f"任务已终态（{task['phase']}），请重新下发")
        if task["phase"] == "CANCEL_REQUESTED":
            raise ApiError(409, "TASK_TERMINAL", "任务正在取消，不能重发")
        retry_count = int(task.get("retry_count") or 0) + 1
        if retry_count > int(self._policy.get("max_retries", 2)):
            task = self._store.update_task(
                cmd_id, phase="FAILED", retry_count=retry_count,
                error_code="RETRY_EXHAUSTED", error_msg="重试次数用尽")
            self._emit(task, "result")
            raise ApiError(409, "RETRY_EXHAUSTED", "重试次数用尽")
        self._store.update_task(cmd_id, retry_count=retry_count)
        ok = self._publish_goal(cmd_id)
        task = self._store.get_task(cmd_id)
        if not ok:
            task = self._store.update_task(
                cmd_id, phase="FAILED", error_code="MQTT_UNAVAILABLE",
                error_msg="MQTT 未连接，重发失败")
            self._emit(task, "result")
            raise ApiError(503, "MQTT_UNAVAILABLE", "MQTT 未连接，重发失败")
        self._store.audit(holder, "task_retry", cmd_id,
                          {"retry_count": retry_count})
        self._emit(task, "publish")
        return self._view(task)

    def cancel(self, cmd_id: str, holder: str) -> dict:
        self._check_holder(holder)
        task = self._store.get_task(cmd_id)
        if not task:
            raise ApiError(404, "NOT_FOUND", f"任务 {cmd_id} 不存在")
        if task["phase"] in TERMINAL:
            raise ApiError(409, "TASK_TERMINAL", f"任务已终态（{task['phase']}）")
        cancel_id = _new_id("cancel")
        payload = {
            "cmd_id": cancel_id,
            "trace_id": task["trace_id"],
            "target_cmd_id": cmd_id,
            "timestamp_ms": _now_ms(),
        }
        if not self._publish("amr/cmd/cancel", payload):
            raise ApiError(503, "MQTT_UNAVAILABLE", "MQTT 未连接，取消失败")
        task = self._store.update_task(cmd_id, phase="CANCEL_REQUESTED")
        self._store.audit(holder, "task_cancel", cmd_id, {"cancel_id": cancel_id})
        self._emit(task, "cancel")
        return {"cmd_id": cancel_id, "target_cmd_id": cmd_id,
                "phase": "CANCEL_REQUESTED"}

    def get_task(self, cmd_id: str) -> dict:
        task = self._store.get_task(cmd_id)
        if not task:
            raise ApiError(404, "NOT_FOUND", f"任务 {cmd_id} 不存在")
        return self._view(task)

    def list_tasks(self, limit: int, phase: str | None) -> list[dict]:
        return [self._view(t) for t in self._store.list_tasks(limit, phase)]

    # ───────────────── 回执 ─────────────────
    def handle_mqtt(self, topic: str, data: dict):
        cmd_id = str(data.get("cmd_id") or "")
        if topic == "amr/cmd/ack":
            self._on_ack(cmd_id, data)
        elif topic == "amr/cmd/feedback":
            self._on_feedback(cmd_id, data)
        elif topic == "amr/cmd/result":
            self._on_result(cmd_id, data)

    def _on_ack(self, cmd_id: str, data: dict):
        task = self._store.get_task(cmd_id)
        if not task:
            # cancel 的 ACK 没有对应任务；未知 cmd_id 只记审计，防止串台
            self._store.audit("robot", "ack_unknown", cmd_id, data)
            return
        if task["phase"] in TERMINAL:
            return
        status = str(data.get("status") or "")
        if status != "ACCEPTED":
            task = self._store.update_task(
                cmd_id, phase="FAILED",
                error_code=data.get("error_code") or "ACK_REJECTED",
                error_msg="机器人拒绝了指令")
            self._emit(task, "result")
            return
        if task["phase"] in ("ACCEPTED", "EXECUTING"):
            return
        task = self._store.update_task(cmd_id, phase="ACCEPTED")
        self._store.audit("robot", "ack", cmd_id, {"latency_ms": data.get("latency_ms")})
        self._emit(task, "ack")

    def _on_feedback(self, cmd_id: str, data: dict):
        task = self._store.get_task(cmd_id)
        if not task or task["phase"] in TERMINAL:
            return
        heartbeat = bool(data.get("heartbeat"))
        phase = task["phase"]
        # 心跳只刷新 updated_at（用于 STALE 判定），不改变相位
        if not heartbeat and phase != "CANCEL_REQUESTED" and phase != "EXECUTING":
            phase = "EXECUTING"
        task = self._store.update_task(cmd_id, phase=phase)
        self._emit(task, "feedback", data)

    def _on_result(self, cmd_id: str, data: dict):
        task = self._store.get_task(cmd_id)
        if not task:
            self._store.audit("robot", "result_unknown", cmd_id, data)
            return
        if task["phase"] in TERMINAL:
            return
        status = str(data.get("status") or "FAILED")
        phase = {"SUCCEEDED": "SUCCEEDED", "CANCELLED": "CANCELLED"}.get(
            status, "FAILED")
        task = self._store.update_task(
            cmd_id, phase=phase, error_code=data.get("error_code"),
            error_msg=data.get("error_msg"),
            result_json=json.dumps(data, ensure_ascii=False))
        self._store.audit("robot", "result", cmd_id, {"status": status})
        self._emit(task, "result", data)

    # ───────────────── 非任务类指令 ─────────────────
    def command(self, name: str, payload: dict, holder: str) -> dict:
        self._check_holder(holder)
        topics = {
            "mode": "amr/cmd/mode",
            "estop": "amr/cmd/estop",
            "return_charge": "amr/cmd/return_charge",
            "inspection_start": "amr/cmd/inspection/start",
            "inspection_stop": "amr/cmd/inspection/stop",
        }
        topic = topics.get(name)
        if not topic:
            raise ApiError(400, "INVALID_ARGUMENT",
                           f"未知指令 {name}（可选：{','.join(topics)}）")
        body = dict(payload or {})
        body.setdefault("cmd_id", _new_id("cmd"))
        body.setdefault("trace_id", _new_id("trace"))
        body.setdefault("timestamp_ms", _now_ms())
        if not self._publish(topic, body):
            raise ApiError(503, "MQTT_UNAVAILABLE", "MQTT 未连接，指令未发出")
        self._store.audit(holder, f"command:{name}", body.get("cmd_id"), body)
        return {"topic": topic, "published": True, "cmd_id": body["cmd_id"]}

    # ───────────────── 周期任务 ─────────────────
    def tick(self):
        now = _now_ms()
        lock = self._store.get_lock()
        if lock and lock.get("holder") and (lock.get("expires_at") or 0) <= now:
            self._store.clear_lock()
            self._store.audit("system", "lock_expired", None,
                              {"holder": lock["holder"]})
            self._hub.broadcast("lock", {"holder": None, "expires_at": None})

        task = self._store.active_task()
        if not task:
            return
        phase = task["phase"]
        age_ack = now - int(task["updated_at"])
        ack_timeout = int(self._policy.get("ack_timeout_ms", 1500))
        feedback_timeout = int(self._policy.get("feedback_timeout_ms", 4000))
        result_timeout = int(self._policy.get("result_timeout_ms", 120000))

        if now - int(task["created_at"]) > result_timeout:
            task = self._store.update_task(
                task["cmd_id"], phase="TIMEOUT", error_code="RESULT_TIMEOUT",
                error_msg="超过预期时间未收到终态")
            self._emit(task, "result")
            return

        if phase == "PUBLISHED" and age_ack > ack_timeout:
            retries = int(task.get("retry_count") or 0)
            if retries < int(self._policy.get("max_retries", 2)):
                self._store.update_task(
                    task["cmd_id"], retry_count=retries + 1,
                    error_code="ACK_TIMEOUT",
                    error_msg="ACK 超时，自动重发")
                ok = self._publish_goal(task["cmd_id"])
                task = self._store.get_task(task["cmd_id"])
                if not ok:
                    task = self._store.update_task(
                        task["cmd_id"], phase="FAILED",
                        error_code="MQTT_UNAVAILABLE",
                        error_msg="重发失败：MQTT 未连接")
                self._store.audit("system", "auto_retry", task["cmd_id"],
                                  {"retry": retries + 1})
                self._emit(task, "retry")
            else:
                task = self._store.update_task(
                    task["cmd_id"], phase="UNKNOWN", error_code="ACK_TIMEOUT",
                    error_msg="ACK 超时且重试次数用尽")
                self._emit(task, "state")
            return

        if phase in ("ACCEPTED", "EXECUTING") and age_ack > feedback_timeout:
            task = self._store.update_task(
                task["cmd_id"], phase="STALE", error_code="FEEDBACK_TIMEOUT",
                error_msg="一段时间未收到 Feedback（心跳也停了）")
            self._emit(task, "state")

    # ───────────────── 输出 ─────────────────
    def _view(self, task: dict) -> dict:
        return {
            "cmd_id": task["cmd_id"],
            "trace_id": task["trace_id"],
            "type": task["type"],
            "payload": task["payload"],
            "phase": task["phase"],
            "created_at": task["created_at"],
            "updated_at": task["updated_at"],
            "retry_count": task.get("retry_count", 0),
            "error_code": task.get("error_code"),
            "error_msg": task.get("error_msg"),
            "result": task.get("result"),
        }

    def _emit(self, task: dict, event: str, data: dict | None = None):
        self._hub.broadcast("task", {
            "cmd_id": task["cmd_id"],
            "phase": task["phase"],
            "event": event,
            "data": data or {},
            "task": self._view(task),
        })
