"""巡检业务节点入口：整合状态机 / 巡检管理 / 路线执行 / 回充

ROS topic 契约（均为 std_msgs/String，payload 为 JSON，与 MQTT 契约一致）：
  订阅：/amr/cmd/mode  /amr/cmd/estop
        /amr/cmd/return_charge  /amr/cmd/inspection/start  /amr/cmd/inspection/stop
  发布：/inspection/status  /battery/state  /amr/status/mode  /amr/alert

单点导航命令 /amr/cmd/goal 由 amr_comm/mission_bridge 转成 Nav2 Action 执行，
本节点不再消费该 topic，避免物理动作重复执行。
"""
import json

import rclpy
from rclpy.node import Node
from std_msgs.msg import String

from .charge_manager import ChargeManager
from .inspection_manager import (InspectionManager, InspectionPoint,
                                 InspectionRoute)
from .mode_state_machine import Mode, ModeStateMachine
from .route_executor import RouteExecutor

_MODE_STR = {'manual': Mode.MANUAL, 'auto': Mode.AUTO,
             'inspect': Mode.INSPECTING, 'charge': Mode.CHARGING}


class InspectionNode(Node):
    def __init__(self):
        super().__init__('inspection_node')

        # 参数
        # 充电桩立柱在 (-4.7,-3.4)，停靠点取标记区东侧，避开 0.4m 膨胀半径
        self.declare_parameter('dock_x', -4.1)
        self.declare_parameter('dock_y', -3.4)
        self.declare_parameter('low_battery_threshold', 20.0)
        self.declare_parameter('status_period', 1.0)
        # 初始电量（默认 100%，P8 低电量回充验证时可调小加速触发）
        self.declare_parameter('initial_level', 100.0)

        self.sm = ModeStateMachine(Mode.MANUAL)
        self.manager = InspectionManager()
        self.route_executor = RouteExecutor(self)
        self.charge = ChargeManager(
            self,
            dock_x=self.get_parameter('dock_x').value,
            dock_y=self.get_parameter('dock_y').value,
            low_threshold=self.get_parameter('low_battery_threshold').value,
            initial_level=self.get_parameter('initial_level').value)

        # ── 发布者 ──
        self.pub_inspection = self.create_publisher(String, '/inspection/status', 10)
        self.pub_battery = self.create_publisher(String, '/battery/state', 10)
        self.pub_mode = self.create_publisher(String, '/amr/status/mode', 10)
        self.pub_alert = self.create_publisher(String, '/amr/alert', 10)

        # ── 订阅者（MQTT 命令经 mqtt_client 桥接到此）──
        self.create_subscription(String, '/amr/cmd/mode', self._on_cmd_mode, 10)
        self.create_subscription(String, '/amr/cmd/estop', self._on_cmd_estop, 10)
        self.create_subscription(String, '/amr/cmd/return_charge',
                                 self._on_cmd_return_charge, 10)
        self.create_subscription(String, '/amr/cmd/inspection/start',
                                 self._on_cmd_inspection_start, 10)
        self.create_subscription(String, '/amr/cmd/inspection/stop',
                                 self._on_cmd_inspection_stop, 10)

        # ── 回调接线 ──
        self.sm.add_listener(self._on_mode_changed)
        self.charge.set_status_callback(self._on_battery_status)
        self.charge.set_low_battery_callback(self._on_low_battery)

        self._last_mode = self.sm.mode
        self._moving = False

        period = self.get_parameter('status_period').value
        self._timer = self.create_timer(period, self._on_tick)
        self._last_tick = self.get_clock().now()

        self.get_logger().info('inspection_node 已启动')
        self._publish_mode()

    # ────────────────────── 命令处理 ──────────────────────
    def _on_cmd_mode(self, msg: String):
        """模式切换：{"mode": "manual|auto|inspect|charge"}"""
        try:
            data = json.loads(msg.data or '{}')
            target = _MODE_STR.get(str(data.get('mode', '')).lower())
        except json.JSONDecodeError as e:
            self.get_logger().warn(f'mode 命令解析失败: {e}')
            return
        if target is None:
            self.get_logger().warn(f'未知模式: {msg.data}')
            return
        self._request_mode(target)

    def _request_mode(self, target: Mode):
        code, text = self.sm.request(target)
        if code == ModeStateMachine.ERR_ILLEGAL_TRANSITION:
            self.get_logger().warn(text)
            self._publish_alert('warn', 'ILLEGAL_MODE', text)
        else:
            self.get_logger().info(f'模式切换: {text}')
        return code == ModeStateMachine.OK

    def _on_cmd_estop(self, msg: String):
        """紧急停止：{"stop": true}"""
        try:
            data = json.loads(msg.data or '{}')
        except json.JSONDecodeError:
            data = {'stop': True}
        if data.get('stop', True):
            self.route_executor.cancel()
            self.sm.estop()
            self._publish_alert('error', 'ESTOP', '紧急停止触发')
            self.get_logger().warn('紧急停止！')

    def _on_cmd_return_charge(self, msg: String):
        """手动回充命令"""
        self._start_charging()

    def _on_cmd_inspection_start(self, msg: String):
        """启动巡检（契约 architecture.md 5.2）：
        {"route_id": "...", "loop": false, "points": [{id,name,x,y,theta,
        dwell_time,capture_photo}, ...]}
        路线数据随命令下发（App 端 Hive 为单一事实来源），收到后登记再执行。
        """
        try:
            data = json.loads(msg.data or '{}')
        except json.JSONDecodeError:
            data = {}
        route_id = str(data.get('route_id', 'route_1'))
        if data.get('points'):
            self._register_route_from_payload(route_id, data)
        points = self.manager.route_points(route_id)
        if not points:
            self.get_logger().warn(f'路线 {route_id} 不存在或无巡检点')
            self._publish_alert('warn', 'ROUTE_EMPTY', f'路线 {route_id} 为空')
            return
        # 切到 INSPECTING（需要先处于 AUTO）
        if self.sm.mode == Mode.MANUAL:
            self.sm.request(Mode.AUTO)
        if not self._request_mode(Mode.INSPECTING):
            return
        ok = self.route_executor.start(points, self._on_route_progress)
        if not ok:
            self.sm.request(Mode.AUTO)

    def _register_route_from_payload(self, route_id: str, data: dict):
        """把 App 下发的路线数据登记到巡检管理器（覆盖同 id 旧数据）"""
        pts = []
        for p in data.get('points', []):
            try:
                pts.append(InspectionPoint(
                    id=str(p['id']),
                    name=str(p.get('name', p['id'])),
                    x=float(p['x']),
                    y=float(p['y']),
                    theta=float(p.get('theta', 0.0)),
                    dwell_time=float(p.get('dwell_time', 3)),
                    capture_photo=bool(p.get('capture_photo', False))))
            except (KeyError, TypeError, ValueError) as e:
                self.get_logger().warn(f'忽略非法巡检点 {p}: {e}')
        if not pts:
            return
        for p in pts:
            self.manager.add_point(p)
        self.manager.add_route(InspectionRoute(
            id=route_id,
            name=route_id,
            point_ids=[p.id for p in pts],
            loop=bool(data.get('loop', False))))

    def _on_cmd_inspection_stop(self, msg: String):
        """停止巡检"""
        if self.sm.mode == Mode.INSPECTING:
            self.route_executor.cancel()
            self.sm.request(Mode.AUTO)

    # ────────────────────── 巡检进度 ──────────────────────
    def _on_route_progress(self, index, total, point, state):
        """路线执行进度回调（执行线程中调用）"""
        payload = {
            'state': 'running' if state not in ('completed', 'failed', 'canceled') else state,
            'progress': index,
            'total': total,
            'current_point': point.id if point else '',
            'point_state': state,
        }
        self._publish_json(self.pub_inspection, payload)
        if state in ('completed', 'failed', 'canceled'):
            self.get_logger().info(f'路线执行结束: {state}')
            # 回到 AUTO
            self.sm.request(Mode.AUTO)

    # ────────────────────── 回充逻辑 ──────────────────────
    def _on_low_battery(self):
        """低电量事件：自动回充"""
        self.get_logger().warn('电量低，启动自动回充')
        self._publish_alert('warn', 'LOW_BATTERY',
                            f'电量低于 {self.charge.low_threshold:.0f}%')
        self._start_charging()

    def _start_charging(self):
        if self.sm.mode == Mode.INSPECTING:
            self.route_executor.cancel()
        # 从任意非 MANUAL 状态进 CHARGING
        if self.sm.mode == Mode.MANUAL:
            self.sm.request(Mode.AUTO)
        if not self._request_mode(Mode.CHARGING):
            return
        ok = self.charge.start_return_to_dock(self._on_dock_done)
        if not ok:
            self.sm.request(Mode.AUTO)

    def _on_dock_done(self, success: bool):
        if not success:
            self._publish_alert('error', 'DOCK_FAILED', '回充导航失败')
            self.sm.request(Mode.AUTO)
            return
        # 已在桩上充电，等充满
        self.get_logger().info('开始充电')

    # ────────────────────── 周期任务 ──────────────────────
    def _on_tick(self):
        now = self.get_clock().now()
        # 钳位 dt：节点用 sim time 时，首个 tick 可能赶上 /clock 跳变
        dt = min(max((now - self._last_tick).nanoseconds / 1e9, 0.0), 5.0)
        self._last_tick = now

        moving = self.sm.mode == Mode.INSPECTING and self.route_executor.running
        self.charge.tick(dt, moving)
        self._publish_battery()

        # 充满电后自动恢复 AUTO
        if self.sm.mode == Mode.CHARGING and self.charge.is_full():
            self.charge.leave_dock()
            self._request_mode(Mode.AUTO)
            self.get_logger().info('充电完成，恢复 AUTO')

    # ────────────────────── 状态发布 ──────────────────────
    def _on_mode_changed(self, old, new):
        self._publish_mode()

    def _publish_mode(self):
        self._publish_json(self.pub_mode, {'mode': self.sm.mode.value})

    def _on_battery_status(self, level, voltage, charging):
        pass  # 由 _publish_battery 统一周期发布

    def _publish_battery(self):
        self._publish_json(self.pub_battery, {
            'level': round(self.charge.level, 1),
            'voltage': round(self.charge.voltage, 2),
            'charging': self.charge.charging,
        })

    def _publish_alert(self, level, code, message):
        self._publish_json(self.pub_alert,
                           {'level': level, 'code': code, 'message': message})

    @staticmethod
    def _publish_json(pub, payload):
        msg = String()
        msg.data = json.dumps(payload)
        pub.publish(msg)


def main(args=None):
    rclpy.init(args=args)
    node = InspectionNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.route_executor.cancel()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
