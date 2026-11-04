"""cmd_vel 超时看门狗：最后一条指令后 timeout_sec 内无新指令，补发一条零速 Twist。

背景（实测）：gz sim 的 DiffDrive 插件不会在指令停止后自动归零，
它会把最后一条非零 /cmd_vel 永久锁存并持续执行。表现是：teleop 松键后
小车仍在原地打转、撞墙后轮子持续空转，/odom 一路漂移几十米，
SLAM/AMCL 的位姿随之发散。

本节点只做一件事：充当 /cmd_vel 的"死手开关"。收到零速指令时不动；
收到非零指令后开始计时，超时则该轮只补发一次零速（补发后不再重复，
避免与本节点自身的订阅产生自激）。
"""
import time

import rclpy
from geometry_msgs.msg import Twist
from rclpy.node import Node

_EPS = 1e-3  # 认为"零速"的阈值


class CmdVelWatchdog(Node):
    def __init__(self):
        super().__init__('cmd_vel_watchdog')

        self.declare_parameter('timeout_sec', 0.5)
        self.declare_parameter('cmd_vel_topic', '/cmd_vel')
        # 检查周期取 timeout 的 1/5，保证超时判定粒度 ≤ 0.1s
        self.declare_parameter('check_period_sec', 0.1)

        self._timeout = float(self.get_parameter('timeout_sec').value)
        topic = self.get_parameter('cmd_vel_topic').value
        period = float(self.get_parameter('check_period_sec').value)

        self._last_cmd_time = 0.0  # 最后一条非零指令的 wall clock
        self._active = False       # 是否存在未超时的非零指令
        self._zero_sent = True     # 本轮零速是否已补发

        self._pub = self.create_publisher(Twist, topic, 10)
        self.create_subscription(Twist, topic, self._on_cmd_vel, 10)
        self.create_timer(period, self._check)

        self.get_logger().info(
            f'cmd_vel watchdog armed: topic={topic} '
            f'timeout={self._timeout:.2f}s')

    def _on_cmd_vel(self, msg: Twist):
        if abs(msg.linear.x) < _EPS and abs(msg.angular.z) < _EPS:
            # 指令本身就是零速（含本节点自己补发的零速）：无需动作
            self._active = False
            self._zero_sent = True
            return
        self._last_cmd_time = time.monotonic()
        self._active = True
        self._zero_sent = False

    def _check(self):
        if not self._active:
            return
        if time.monotonic() - self._last_cmd_time < self._timeout:
            return
        self._pub.publish(Twist())  # 全零 Twist
        self._active = False
        self._zero_sent = True
        self.get_logger().warn(
            f'no /cmd_vel for {self._timeout:.2f}s -> published zero Twist')


def main(args=None):
    rclpy.init(args=args)
    node = CmdVelWatchdog()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
