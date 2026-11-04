"""Nav2 启动：复用 nav2_bringup/bringup_launch.py"""
import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration


def generate_launch_description():
    nav_share = get_package_share_directory('amr_nav')
    nav2_bringup_share = get_package_share_directory('nav2_bringup')

    default_map = os.path.join(nav_share, 'maps', 'indoor.yaml')
    default_params = os.path.join(nav_share, 'config', 'nav2_params.yaml')

    declare_args = [
        DeclareLaunchArgument('map', default_value=default_map,
                              description='地图 yaml 完整路径'),
        DeclareLaunchArgument('params_file', default_value=default_params,
                              description='Nav2 参数文件完整路径'),
        DeclareLaunchArgument('use_sim_time', default_value='true',
                              description='使用仿真时间'),
    ]

    nav2 = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(nav2_bringup_share, 'launch', 'bringup_launch.py')),
        launch_arguments={
            'map': LaunchConfiguration('map'),
            'params_file': LaunchConfiguration('params_file'),
            'use_sim_time': LaunchConfiguration('use_sim_time'),
            'autostart': 'true',
        }.items(),
    )

    return LaunchDescription(declare_args + [nav2])
