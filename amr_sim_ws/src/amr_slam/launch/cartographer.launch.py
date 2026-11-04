"""Cartographer 2D 建图启动：cartographer_node + occupancy_grid_node"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    config_dir = os.path.join(
        get_package_share_directory('amr_slam'), 'config')
    config_basename = 'cartographer_2d.lua'

    use_sim_time = LaunchConfiguration('use_sim_time')

    declare_args = [
        DeclareLaunchArgument('use_sim_time', default_value='true',
                              description='使用仿真时间'),
    ]

    cartographer_node = Node(
        package='cartographer_ros',
        executable='cartographer_node',
        output='screen',
        parameters=[{'use_sim_time': use_sim_time}],
        arguments=[
            '-configuration_directory', config_dir,
            '-configuration_basename', config_basename,
        ],
        remappings=[('scan', '/scan'), ('imu', '/imu/data'), ('odom', '/odom')],
    )

    occupancy_grid_node = Node(
        package='cartographer_ros',
        executable='cartographer_occupancy_grid_node',
        output='screen',
        parameters=[{'use_sim_time': use_sim_time}],
        arguments=['-resolution', '0.05', '-publish_period_sec', '1.0'],
    )

    return LaunchDescription(declare_args + [
        cartographer_node,
        occupancy_grid_node,
    ])
