"""rosbridge WebSocket 服务启动（端口 9090，供 Flutter 订阅数据下行）"""
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    declare_args = [
        DeclareLaunchArgument('port', default_value='9090',
                              description='WebSocket 监听端口'),
    ]

    rosbridge = Node(
        package='rosbridge_server',
        executable='rosbridge_websocket',
        output='screen',
        parameters=[{
            'port': LaunchConfiguration('port'),
            'address': '',
            'use_sim_time': True,
        }],
    )

    return LaunchDescription(declare_args + [rosbridge])
