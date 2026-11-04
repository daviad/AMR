"""MQTT 桥启动：mosquitto 需已在本机运行（1883），本 launch 启动 mqtt_client 节点"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description():
    config = os.path.join(
        get_package_share_directory('amr_comm'), 'config', 'mqtt_client.yaml')

    mqtt_client_node = Node(
        package='mqtt_client',
        executable='mqtt_client',
        name='mqtt_client',
        output='screen',
        parameters=[config, {'use_sim_time': True}],
    )

    return LaunchDescription([mqtt_client_node])
