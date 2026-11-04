"""路线执行器：通过 Nav2 NavigateToPose Action 顺序执行巡检点"""
import math
import threading
import time
from typing import Callable, List, Optional

from action_msgs.msg import GoalStatus
from geometry_msgs.msg import PoseStamped, Quaternion
from nav2_msgs.action import NavigateToPose
from rclpy.action import ActionClient
from rclpy.node import Node

from .inspection_manager import InspectionPoint


def yaw_to_quaternion(yaw: float) -> Quaternion:
    q = Quaternion()
    q.z = math.sin(yaw / 2.0)
    q.w = math.cos(yaw / 2.0)
    return q


class RouteExecutor:
    """按顺序向 Nav2 发送导航目标，逐点执行"""

    def __init__(self, node: Node):
        self._node = node
        self._client = ActionClient(node, NavigateToPose, 'navigate_to_pose')
        self._thread: Optional[threading.Thread] = None
        self._cancel_event = threading.Event()
        self._goal_handle = None
        self._progress_cb: Optional[Callable] = None

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self, points: List[InspectionPoint],
              progress_cb: Callable) -> bool:
        """启动路线执行。progress_cb(index, total, point, state)"""
        if self.running:
            self._node.get_logger().warn('路线已在执行中')
            return False
        if not points:
            self._node.get_logger().warn('路线为空')
            return False
        self._cancel_event.clear()
        self._progress_cb = progress_cb
        self._thread = threading.Thread(
            target=self._run, args=(list(points),), daemon=True)
        self._thread.start()
        return True

    def cancel(self):
        """请求取消当前路线"""
        self._cancel_event.set()
        if self._goal_handle is not None:
            try:
                self._goal_handle.cancel_goal_async()
            except Exception:
                pass

    def _notify(self, index, total, point, state):
        if self._progress_cb:
            try:
                self._progress_cb(index, total, point, state)
            except Exception:
                pass

    def _run(self, points: List[InspectionPoint]):
        total = len(points)
        self._node.get_logger().info(f'开始执行路线，共 {total} 个点')
        for idx, pt in enumerate(points):
            if self._cancel_event.is_set():
                self._notify(idx, total, pt, 'canceled')
                return
            self._notify(idx, total, pt, 'navigating')
            ok = self._navigate_to(pt)
            if not ok:
                self._notify(idx, total, pt, 'failed')
                return
            self._notify(idx, total, pt, 'arrived')
            # 停留
            end = time.time() + max(pt.dwell_time, 0.0)
            while time.time() < end:
                if self._cancel_event.is_set():
                    self._notify(idx, total, pt, 'canceled')
                    return
                time.sleep(0.1)
            self._notify(idx, total, pt, 'done')
        self._notify(total, total, None, 'completed')

    def _navigate_to(self, pt: InspectionPoint) -> bool:
        """发送单个导航目标并阻塞等待结果"""
        if not self._client.wait_for_server(timeout_sec=5.0):
            self._node.get_logger().error('Nav2 navigate_to_pose 服务不可用')
            return False

        goal = NavigateToPose.Goal()
        goal.pose = PoseStamped()
        goal.pose.header.frame_id = 'map'
        goal.pose.header.stamp = self._node.get_clock().now().to_msg()
        goal.pose.pose.position.x = pt.x
        goal.pose.pose.position.y = pt.y
        goal.pose.pose.orientation = yaw_to_quaternion(pt.theta)

        send_future = self._client.send_goal_async(goal)
        while not send_future.done():
            if self._cancel_event.is_set():
                return False
            time.sleep(0.05)
        self._goal_handle = send_future.result()
        if self._goal_handle is None or not self._goal_handle.accepted:
            self._node.get_logger().warn(f'目标点 {pt.id} 被拒绝')
            return False

        result_future = self._goal_handle.get_result_async()
        while not result_future.done():
            if self._cancel_event.is_set():
                return False
            time.sleep(0.1)
        result = result_future.result()
        return result is not None and result.status == GoalStatus.STATUS_SUCCEEDED
