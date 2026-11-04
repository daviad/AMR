#!/usr/bin/env python3
"""业务指令桥：MQTT 指令语义 ⟷ Nav2 NavigateToPose Action。

职责边界（与 docs/architecture.md 5.2 一致）：
  MQTT QoS 只保证"到达下一个节点"；本节点补上业务语义：
    - cmd_id 幂等：重复指令不重复执行，只回放上一次 ACK/Result；
    - 指令生命周期：ACK → FEEDBACK → RESULT；
    - Nav2 Action Feedback/Result 透传（不做"成功/失败"二元拍平）；
    - 取消：cancel_goal + CANCELLED 终态；
    - 端到端 trace：MQTT 收到 → Goal 发出 → 首次 Feedback → Result。

订阅（std_msgs/String，payload JSON）：
  /amr/cmd/goal    {cmd_id, trace_id, timestamp_ms, ttl_ms, payload:{x,y,theta}}
  /amr/cmd/cancel  {cmd_id, trace_id, target_cmd_id}
发布：
  /amr/cmd/ack  /amr/cmd/feedback  /amr/cmd/result  /amr/trace
"""
import json
import threading
import time
from collections import OrderedDict

import rclpy
from action_msgs.msg import GoalStatus
from geometry_msgs.msg import PoseStamped, Quaternion
from nav2_msgs.action import NavigateToPose
from rclpy.action import ActionClient
from rclpy.node import Node
from std_msgs.msg import String

import math


def _now_ms():
    return int(time.time() * 1000)


def _quat_from_yaw(yaw: float) -> Quaternion:
    q = Quaternion()
    q.z = math.sin(yaw / 2.0)
    q.w = math.cos(yaw / 2.0)
    return q


class ActiveCommand:
    def __init__(self, cmd_id, trace_id, payload, received_ms, received_mono):
        self.cmd_id = cmd_id
        self.trace_id = trace_id
        self.payload = payload
        self.received_ms = received_ms
        self.received_mono = received_mono
        self.goal_handle = None
        self.last_feedback = None
        self.last_feedback_mono = 0.0
        self.last_recoveries = 0
        self.goal_sent_mono = 0.0
        self.first_feedback_mono = 0.0
        self.cancel_requested = False


class MissionBridge(Node):
    def __init__(self):
        super().__init__('mission_bridge')
        self.declare_parameter('feedback_period_sec', 1.0)
        self.declare_parameter('heartbeat_feedback', True)
        self.declare_parameter('ack_timeout_sec', 3.0)
        self.declare_parameter('trace_log_path', '/tmp/amr_trace.jsonl')
        # 故障注入：用于验证 App 侧 UNKNOWN / STALE 分支
        self.declare_parameter('fault_drop_ack', False)
        self.declare_parameter('fault_drop_result', False)
        self.declare_parameter('fault_extra_delay_ms', 0)

        self.heartbeat = bool(self.get_parameter('heartbeat_feedback').value)
        self.ack_timeout = float(self.get_parameter('ack_timeout_sec').value)
        self.fault_drop_ack = bool(
            self.get_parameter('fault_drop_ack').value)
        self.fault_drop_result = bool(
            self.get_parameter('fault_drop_result').value)
        self.extra_delay_ms = int(
            self.get_parameter('fault_extra_delay_ms').value)
        self.trace_path = str(self.get_parameter('trace_log_path').value)

        self._lock = threading.RLock()
        self._active: ActiveCommand | None = None
        self._seen: OrderedDict[str, dict] = OrderedDict()
        self._seq = 0

        self.pub_ack = self.create_publisher(String, '/amr/cmd/ack', 10)
        self.pub_feedback = self.create_publisher(
            String, '/amr/cmd/feedback', 10)
        self.pub_result = self.create_publisher(String, '/amr/cmd/result', 10)
        self.pub_trace = self.create_publisher(String, '/amr/trace', 10)

        self.create_subscription(
            String, '/amr/cmd/goal', self._on_goal_cmd, 10)
        self.create_subscription(
            String, '/amr/cmd/cancel', self._on_cancel_cmd, 10)

        self._client = ActionClient(self, NavigateToPose, 'navigate_to_pose')
        period = float(self.get_parameter('feedback_period_sec').value)
        self._timer = self.create_timer(max(period, 0.2), self._on_tick)

        self.get_logger().info(
            'mission_bridge 已启动：/amr/cmd/goal -> NavigateToPose Action')
        self._trace('bridge_started', None, None)

    # ─────────────────────── 命令入口 ───────────────────────
    def _on_goal_cmd(self, msg: String):
        received_mono = time.monotonic()
        try:
            data = json.loads(msg.data or '{}')
        except json.JSONDecodeError as e:
            self.get_logger().warn(f'goal 命令 JSON 解析失败: {e}')
            return

        cmd_id = str(data.get('cmd_id') or self._new_id('cmd'))
        trace_id = str(data.get('trace_id') or cmd_id)
        payload = data.get('payload')
        if not isinstance(payload, dict):
            payload = data  # 兼容旧格式 {x,y,theta}
        try:
            x = float(payload['x'])
            y = float(payload['y'])
            yaw = float(payload.get('theta', payload.get('yaw', 0.0)))
        except (KeyError, TypeError, ValueError):
            self._reject(cmd_id, trace_id, 'BAD_PAYLOAD', '缺少 x/y')
            return

        self._trace('mqtt_received', trace_id, cmd_id, extra={
            'x': x, 'y': y, 'yaw': yaw,
            'mqtt_to_bridge_ms': 0.0,
        })

        # TTL：过期指令直接拒绝，避免"迟到的物理动作"
        ttl_ms = int(data.get('ttl_ms', 0) or 0)
        stamp_ms = int(data.get('timestamp_ms', 0) or 0)
        if ttl_ms > 0 and stamp_ms > 0:
            age_ms = _now_ms() - stamp_ms
            if age_ms > ttl_ms:
                self._reject(cmd_id, trace_id, 'EXPIRED',
                             f'指令已过期 {age_ms}ms > ttl {ttl_ms}ms')
                return

        # 幂等：重复 cmd_id 不重复执行，回放已有 ACK / Feedback / Result
        with self._lock:
            seen = self._seen.get(cmd_id)
            if seen is not None:
                self.get_logger().info(f'重复 cmd_id={cmd_id}，回放上次结果')
                self._replay(seen)
                self._trace('duplicate_replayed', trace_id, cmd_id)
                return
            if self._active is not None:
                self._reject(cmd_id, trace_id, 'BUSY',
                             f'当前正在执行 {self._active.cmd_id}')
                return
            active = ActiveCommand(cmd_id, trace_id, payload,
                                   _now_ms(), received_mono)
            self._active = active
            self._seen[cmd_id] = {'ack': None, 'feedback': None,
                                  'result': None}
            self._seen.move_to_end(cmd_id)
            while len(self._seen) > 256:
                self._seen.popitem(last=False)

        if not self._client.wait_for_server(timeout_sec=0.5):
            self._finish(active, 'FAILED', 'NAV2_UNAVAILABLE',
                         'navigate_to_pose action server 不可用')
            return

        goal = NavigateToPose.Goal()
        goal.pose = PoseStamped()
        goal.pose.header.frame_id = str(payload.get('frame_id', 'map'))
        goal.pose.header.stamp = self.get_clock().now().to_msg()
        goal.pose.pose.position.x = x
        goal.pose.pose.position.y = y
        goal.pose.pose.orientation = _quat_from_yaw(yaw)

        active.goal_sent_mono = time.monotonic()
        self._trace('goal_sent', trace_id, cmd_id)
        future = self._client.send_goal_async(
            goal, feedback_callback=self._on_action_feedback)
        future.add_done_callback(
            lambda f, a=active: self._on_goal_response(f, a))

    def _on_goal_response(self, future, active: ActiveCommand):
        try:
            goal_handle = future.result()
        except Exception as e:
            self._finish(active, 'FAILED', 'GOAL_SEND_FAILED', str(e))
            return
        if goal_handle is None or not goal_handle.accepted:
            self._finish(active, 'FAILED', 'GOAL_REJECTED',
                         'Nav2 拒绝目标（可能超出地图/不可达）')
            return
        with self._lock:
            if self._active is not active:
                # 已被取消/替换，避免悬挂 goal
                goal_handle.cancel_goal_async()
                return
            active.goal_handle = goal_handle
            if active.cancel_requested:
                goal_handle.cancel_goal_async()
            ack = {
                'cmd_id': active.cmd_id,
                'trace_id': active.trace_id,
                'type': 'ACK',
                'status': 'ACCEPTED',
                'timestamp_ms': _now_ms(),
                'latency_ms': round(
                    (time.monotonic() - active.received_mono) * 1000.0, 2),
            }
            self._seen[active.cmd_id]['ack'] = ack
        self._trace('goal_accepted', active.trace_id, active.cmd_id,
                    latency_ms=ack['latency_ms'])
        if not self.fault_drop_ack:
            self._publish(self.pub_ack, ack)
        else:
            self._trace('ack_dropped_by_fault', active.trace_id, active.cmd_id)
        result_future = goal_handle.get_result_async()
        result_future.add_done_callback(
            lambda f, a=active: self._on_action_result(f, a))

    def _on_action_feedback(self, feedback_msg):
        with self._lock:
            active = self._active
            if active is None:
                return
            fb = feedback_msg.feedback
            recoveries = int(fb.number_of_recoveries)
            nav_state = 'CONTROLLING'
            if time.monotonic() - active.goal_sent_mono < 1.0:
                nav_state = 'PLANNING'
            if recoveries > active.last_recoveries:
                nav_state = 'RECOVERING'
            active.last_recoveries = recoveries
            active.last_feedback_mono = time.monotonic()
            if active.first_feedback_mono == 0.0:
                active.first_feedback_mono = active.last_feedback_mono
                self._trace('first_feedback', active.trace_id, active.cmd_id,
                            latency_ms=round(
                                (active.first_feedback_mono -
                                 active.received_mono) * 1000.0, 2))
            eta = fb.estimated_time_remaining.sec + (
                fb.estimated_time_remaining.nanosec / 1e9)
            payload = {
                'cmd_id': active.cmd_id,
                'trace_id': active.trace_id,
                'type': 'FEEDBACK',
                'state': 'EXECUTING',
                'nav_state': nav_state,
                'number_of_recoveries': recoveries,
                'distance_remaining': round(float(fb.distance_remaining), 3),
                'eta_sec': round(float(eta), 1),
                'timestamp_ms': _now_ms(),
            }
            active.last_feedback = payload
            self._seen[active.cmd_id]['feedback'] = payload
        self._publish(self.pub_feedback, payload)

    def _on_action_result(self, future, active: ActiveCommand):
        try:
            wrapped = future.result()
        except Exception as e:
            self._finish(active, 'FAILED', 'RESULT_ERROR', str(e))
            return
        status = wrapped.status
        result = wrapped.result
        if status == GoalStatus.STATUS_SUCCEEDED:
            self._finish(active, 'SUCCEEDED', None, None)
        elif status == GoalStatus.STATUS_CANCELED:
            self._finish(active, 'CANCELLED', 'CANCELLED_BY_USER', None)
        else:
            code = getattr(result, 'error_code', 0) if result else 0
            msg = getattr(result, 'error_msg', '') if result else ''
            self._finish(active, 'FAILED',
                         f'NAV2_ERROR_{code}' if code else 'NAV2_ABORTED',
                         msg or 'Nav2 中止（规划/控制/恢复耗尽）')

    def _on_cancel_cmd(self, msg: String):
        try:
            data = json.loads(msg.data or '{}')
        except json.JSONDecodeError as e:
            self.get_logger().warn(f'cancel 命令 JSON 解析失败: {e}')
            return
        cancel_id = str(data.get('cmd_id') or self._new_id('cancel'))
        trace_id = str(data.get('trace_id') or cancel_id)
        target = str(data.get('target_cmd_id') or '')
        with self._lock:
            active = self._active
            if active is None or (target and target != active.cmd_id):
                ack = {
                    'cmd_id': cancel_id, 'trace_id': trace_id,
                    'type': 'ACK', 'status': 'ACCEPTED', 'action': 'CANCEL',
                    'target_cmd_id': target, 'timestamp_ms': _now_ms(),
                    'latency_ms': 0.0,
                }
                self._publish(self.pub_ack, ack)
                self._publish(self.pub_result, {
                    'cmd_id': target or cancel_id, 'trace_id': trace_id,
                    'type': 'RESULT', 'status': 'FAILED',
                    'error_code': 'NO_ACTIVE_COMMAND',
                    'timestamp_ms': _now_ms(),
                })
                return
            active.cancel_requested = True
            goal_handle = active.goal_handle
        ack = {
            'cmd_id': cancel_id, 'trace_id': trace_id,
            'type': 'ACK', 'status': 'ACCEPTED', 'action': 'CANCEL',
            'target_cmd_id': active.cmd_id, 'timestamp_ms': _now_ms(),
            'latency_ms': 0.0,
        }
        self._publish(self.pub_ack, ack)
        self._trace('cancel_requested', trace_id, active.cmd_id)
        if goal_handle is not None:
            goal_handle.cancel_goal_async()

    def _on_tick(self):
        """心跳 Feedback：Nav2 feedback 稀疏时避免 App 误判 STALE。"""
        if not self.heartbeat:
            return
        with self._lock:
            active = self._active
            if active is None or active.last_feedback is None:
                return
            if time.monotonic() - active.last_feedback_mono > 10.0:
                return
            payload = dict(active.last_feedback)
        payload['timestamp_ms'] = _now_ms()
        payload['heartbeat'] = True
        self._publish(self.pub_feedback, payload)

    # ─────────────────────── 响应辅助 ───────────────────────
    def _reject(self, cmd_id, trace_id, code, message):
        self._finish_orphan(cmd_id, trace_id, code, message)

    def _finish_orphan(self, cmd_id, trace_id, code, message):
        result = {
            'cmd_id': cmd_id, 'trace_id': trace_id, 'type': 'RESULT',
            'status': 'FAILED', 'error_code': code, 'error_msg': message,
            'timestamp_ms': _now_ms(),
        }
        self._publish(self.pub_ack, {
            'cmd_id': cmd_id, 'trace_id': trace_id, 'type': 'ACK',
            'status': 'REJECTED', 'error_code': code,
            'timestamp_ms': _now_ms(), 'latency_ms': 0.0,
        })
        self._publish(self.pub_result, result)
        self._trace('command_rejected', trace_id, cmd_id,
                    error_code=code, extra={'message': message})

    def _finish(self, active: ActiveCommand, status, error_code, error_msg):
        latency = round((time.monotonic() - active.received_mono) * 1000.0, 2)
        result = {
            'cmd_id': active.cmd_id, 'trace_id': active.trace_id,
            'type': 'RESULT', 'status': status,
            'error_code': error_code, 'error_msg': error_msg,
            'timestamp_ms': _now_ms(),
            'latency_ms': latency,
            'total_recoveries': active.last_recoveries,
        }
        with self._lock:
            if active.cmd_id in self._seen:
                self._seen[active.cmd_id]['result'] = result
            if self._active is active:
                self._active = None
        self._trace('result', active.trace_id, active.cmd_id,
                    latency_ms=latency, error_code=error_code,
                    extra={'status': status})
        if not self.fault_drop_result:
            self._publish(self.pub_result, result)
        else:
            self._trace('result_dropped_by_fault', active.trace_id,
                        active.cmd_id)

    def _replay(self, seen):
        if seen.get('ack') is not None:
            self._publish(self.pub_ack, seen['ack'])
        if seen.get('feedback') is not None and seen.get('result') is None:
            self._publish(self.pub_feedback, seen['feedback'])
        if seen.get('result') is not None:
            self._publish(self.pub_result, seen['result'])

    # ─────────────────────── 发布 / trace ───────────────────────
    def _publish(self, pub, payload):
        if self.extra_delay_ms > 0:
            # 故障注入：同步延迟会阻塞执行器，仅用于小延迟实验
            time.sleep(self.extra_delay_ms / 1000.0)
        msg = String()
        msg.data = json.dumps(payload, ensure_ascii=False)
        pub.publish(msg)

    def _trace(self, event, trace_id, cmd_id, latency_ms=None,
               error_code=None, extra=None):
        record = {
            'component': 'mission_bridge',
            'event': event,
            'trace_id': trace_id,
            'cmd_id': cmd_id,
            'timestamp_ms': _now_ms(),
            'latency_ms': latency_ms,
            'error_code': error_code,
        }
        if extra:
            record.update(extra)
        try:
            msg = String()
            msg.data = json.dumps(record, ensure_ascii=False)
            self.pub_trace.publish(msg)
            if self.trace_path:
                with open(self.trace_path, 'a', encoding='utf-8') as f:
                    f.write(json.dumps(record, ensure_ascii=False) + '\n')
        except Exception as e:
            self.get_logger().debug(f'trace 写入失败: {e}')

    def _new_id(self, prefix):
        self._seq += 1
        return f'{prefix}-{int(time.time() * 1000)}-{self._seq}'


def main():
    rclpy.init()
    node = MissionBridge()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
