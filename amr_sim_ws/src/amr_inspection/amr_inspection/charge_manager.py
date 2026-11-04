"""回充管理：模拟电量消耗 / 充电，低电量触发回充流程"""
import math
import threading
import time
from typing import Callable, Optional

from geometry_msgs.msg import PoseStamped
from nav2_msgs.action import NavigateToPose
from rclpy.action import ActionClient
from rclpy.node import Node

from .route_executor import yaw_to_quaternion


class ChargeManager:
    """仿真电池模型 + 回充调度（与 mode_state_machine 配合）"""

    def __init__(self, node: Node,
                 dock_x: float = -4.1, dock_y: float = -3.4,
                 low_threshold: float = 20.0,
                 full_threshold: float = 95.0,
                 initial_level: float = 100.0):
        self._node = node
        self.dock_x = dock_x
        self.dock_y = dock_y
        self.low_threshold = low_threshold
        self.full_threshold = full_threshold

        self._level = float(initial_level)  # 当前电量 %
        self._voltage = 12.6
        self._charging = False
        self._at_dock = False
        self._navigating_to_dock = False
        self._lock = threading.Lock()
        self._client = ActionClient(node, NavigateToPose, 'navigate_to_pose')
        # 电量状态变化回调 cb(level, voltage, charging)
        self._status_cb: Optional[Callable] = None
        # 低电量事件回调 cb()
        self._low_battery_cb: Optional[Callable] = None
        self._low_fired = False

    # ── 状态查询 ──
    @property
    def level(self) -> float:
        with self._lock:
            return self._level

    @property
    def charging(self) -> bool:
        with self._lock:
            return self._charging

    @property
    def voltage(self) -> float:
        with self._lock:
            return self._voltage

    def set_status_callback(self, cb: Callable):
        self._status_cb = cb

    def set_low_battery_callback(self, cb: Callable):
        self._low_battery_cb = cb

    # ── 电池仿真（由节点定时器周期调用，dt 秒）──
    def tick(self, dt: float, moving: bool):
        with self._lock:
            if self._charging and self._at_dock:
                # 充电：约 2 分钟充满
                self._level = min(100.0, self._level + dt * (100.0 / 120.0))
            else:
                # 放电：移动约 40 分钟耗尽，静止约 80 分钟
                rate = 100.0 / 2400.0 if moving else 100.0 / 4800.0
                self._level = max(0.0, self._level - dt * rate)
            # 简单电压模型：12.6V 满电 ~ 10.5V 空电
            self._voltage = 10.5 + (12.6 - 10.5) * self._level / 100.0
            level = self._level
            charging = self._charging

        if self._status_cb:
            try:
                self._status_cb(level, self._voltage, charging)
            except Exception:
                pass

        if level <= self.low_threshold and not self._low_fired:
            self._low_fired = True
            if self._low_battery_cb:
                try:
                    self._low_battery_cb()
                except Exception:
                    pass
        elif level >= self.full_threshold:
            self._low_fired = False

    # ── 回充流程 ──
    def start_return_to_dock(self, done_cb: Callable) -> bool:
        """导航到充电桩。done_cb(success)"""
        if self._navigating_to_dock:
            return False
        if not self._client.wait_for_server(timeout_sec=5.0):
            self._node.get_logger().error('Nav2 不可用，无法回充')
            return False
        self._navigating_to_dock = True

        goal = NavigateToPose.Goal()
        goal.pose = PoseStamped()
        goal.pose.header.frame_id = 'map'
        goal.pose.header.stamp = self._node.get_clock().now().to_msg()
        goal.pose.pose.position.x = self.dock_x
        goal.pose.pose.position.y = self.dock_y
        goal.pose.pose.orientation = yaw_to_quaternion(0.0)

        future = self._client.send_goal_async(goal)
        future.add_done_callback(
            lambda f: self._on_goal_sent(f, done_cb))
        return True

    def _on_goal_sent(self, future, done_cb):
        handle = future.result()
        if handle is None or not handle.accepted:
            self._navigating_to_dock = False
            done_cb(False)
            return
        result_future = handle.get_result_async()
        result_future.add_done_callback(
            lambda f: self._on_dock_result(f, done_cb))

    def _on_dock_result(self, future, done_cb):
        result = future.result()
        success = result is not None and result.status == 4  # SUCCEEDED
        self._navigating_to_dock = False
        with self._lock:
            self._at_dock = success
            self._charging = success
        self._node.get_logger().info(
            '到达充电桩，开始充电' if success else '回充导航失败')
        done_cb(success)

    def is_full(self) -> bool:
        with self._lock:
            return self._level >= self.full_threshold

    def leave_dock(self):
        """充满后离开充电桩状态"""
        with self._lock:
            self._at_dock = False
            self._charging = False
